package com.iaportafolio.argos.terminal

import android.annotation.SuppressLint
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.Typeface
import android.util.TypedValue
import android.view.ActionMode
import android.view.GestureDetector
import android.view.HapticFeedbackConstants
import android.view.InputDevice
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.Menu
import android.view.MenuItem
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.View
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import android.widget.Scroller
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.iaportafolio.argos.R
import com.iaportafolio.argos.data.TerminalSettings
import com.iaportafolio.argos.ui.terminal.StickyModifiers
import com.termux.terminal.KeyHandler
import com.termux.terminal.TerminalEmulator
import com.termux.view.TerminalRenderer
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Vista del terminal remoto: pinta un [RemoteTerminalSession] con el `TerminalRenderer` de
 * Termux y traduce teclado (IME y físico), gestos, ratón y selección. Es la versión ligera
 * de `TerminalView` de Termux (Apache 2.0) sin `TerminalSession` local.
 *
 * Scroll como en iOS/Termux: si la app remota (tmux con `mouse on`) sigue el ratón, se envían
 * eventos de rueda (tmux entra en modo copia y desplaza su historial); en pantalla alternativa
 * sin ratón, flechas; si no, se desplaza el historial local.
 */
@SuppressLint("ViewConstructor")
class RemoteTerminalView(context: Context, private val callbacks: Callbacks) : View(context) {

    /** Lo que la vista delega en el ViewModel. */
    interface Callbacks {
        fun onText(text: CharSequence)
        fun onCodePoint(codePoint: Int, ctrl: Boolean, alt: Boolean)
        fun onKeySequence(sequence: String)
        fun onPaste(text: String)
        fun modifiers(): StickyModifiers
        fun onSizeChanged(columns: Int, rows: Int)
        fun onFontSizeChanged(sp: Int)
    }

    private var session: RemoteTerminalSession? = null
    private var fontSizeSp = TerminalSettings.DEFAULT_FONT_SIZE_SP
    private var renderer = TerminalRenderer(spToPx(fontSizeSp), Typeface.MONOSPACE)
    private var lineSpacingAndAscent = lineSpacingAndAscent(fontSizeSp)

    /** Fila superior visible: de -historial a 0. */
    private var topRow = 0
    private var scrollRemainder = 0f
    private var combiningAccent = 0
    private val scroller = Scroller(context)

    private var selection: Selection? = null
    private var selecting = false
    private var actionMode: ActionMode? = null

    private var pinchBaseSp = fontSizeSp
    private var pinchScale = 1f

    private val sessionListener = object : RemoteTerminalSession.Listener {
        override fun onScreenUpdated() = this@RemoteTerminalView.onScreenUpdated()
        override fun onCopyToClipboard(text: String) = copyFromRemote(text)
        override fun onPasteRequested() = pasteFromClipboard()
        override fun onBell() {
            performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
        }
    }

    init {
        isFocusable = true
        isFocusableInTouchMode = true
        isVerticalScrollBarEnabled = true
    }

    // MARK: - Enlace con la sesión

    fun attach(target: RemoteTerminalSession) {
        if (session === target) return
        session?.listener = null
        session = target
        target.listener = sessionListener
        topRow = 0
        updateSize(force = true)
        invalidate()
    }

    fun detach() {
        session?.listener = null
        session = null
        actionMode?.finish()
    }

    fun setFontSize(sp: Int) {
        val clamped = TerminalSettings.clampFontSize(sp)
        if (clamped == fontSizeSp) return
        fontSizeSp = clamped
        renderer = TerminalRenderer(spToPx(clamped), Typeface.MONOSPACE)
        lineSpacingAndAscent = lineSpacingAndAscent(clamped)
        updateSize(force = false)
        invalidate()
    }

    /** Muestra el teclado si está oculto y viceversa. */
    fun toggleKeyboard() {
        val imm = context.getSystemService(InputMethodManager::class.java) ?: return
        val visible = ViewCompat.getRootWindowInsets(this)?.isVisible(WindowInsetsCompat.Type.ime()) == true
        if (visible) imm.hideSoftInputFromWindow(windowToken, 0) else showKeyboard()
    }

    fun showKeyboard() {
        requestFocus()
        context.getSystemService(InputMethodManager::class.java)?.showSoftInput(this, InputMethodManager.SHOW_IMPLICIT)
    }

    fun pasteFromClipboard() {
        val clipboard = context.getSystemService(ClipboardManager::class.java) ?: return
        val text = clipboard.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(context)?.toString()
        if (!text.isNullOrEmpty()) callbacks.onPaste(text)
    }

    // MARK: - Tamaño y pintado

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) = updateSize(force = false)

    private fun updateSize(force: Boolean) {
        val emulator = session?.emulator ?: return
        if (width == 0 || height == 0) return
        val columns = max(MIN_GRID, (width / renderer.fontWidth).toInt())
        val rows = max(MIN_GRID, (height - lineSpacingAndAscent) / renderer.fontLineSpacing)
        val changed = columns != emulator.mColumns || rows != emulator.mRows
        if (changed) {
            session?.resize(columns, rows, renderer.fontWidth.toInt(), renderer.fontLineSpacing)
            topRow = 0
            clearSelection()
            invalidate()
        }
        if (changed || force) callbacks.onSizeChanged(columns, rows)
    }

    override fun onDraw(canvas: Canvas) {
        val emulator = session?.emulator
        if (emulator == null) {
            canvas.drawColor(BACKGROUND)
            return
        }
        val range = selection?.normalized()
        renderer.render(
            emulator,
            canvas,
            topRow,
            range?.startRow ?: -1,
            range?.endRow ?: -1,
            range?.startColumn ?: -1,
            range?.endColumn ?: -1,
        )
    }

    override fun isOpaque(): Boolean = true

    override fun computeVerticalScrollRange(): Int = session?.emulator?.screen?.activeRows ?: 1

    override fun computeVerticalScrollExtent(): Int = session?.emulator?.mRows ?: 1

    override fun computeVerticalScrollOffset(): Int {
        val emulator = session?.emulator ?: return 0
        return emulator.screen.activeRows + topRow - emulator.mRows
    }

    private fun onScreenUpdated() {
        val emulator = session?.emulator ?: return
        val history = emulator.screen.activeTranscriptRows
        val shift = emulator.scrollCounter
        val current = selection
        if (current != null) {
            // Con texto seleccionado no se salta al final: la selección se desplaza con el texto.
            selection = current.shifted(-shift)
            topRow = (topRow - shift).coerceIn(-history, 0)
        } else {
            topRow = 0
        }
        emulator.clearScrollCounter()
        invalidate()
    }

    // MARK: - Teclado del sistema (IME)

    override fun onCheckIsTextEditor(): Boolean = true

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection {
        // Texto «visible password»: sin autocorrección ni predicciones (rompen la entrada en un
        // terminal), pero con acentos, ñ y emoji vía commitText. Sin aprendizaje: en un
        // terminal se teclean contraseñas.
        outAttrs.inputType = EditorInfo.TYPE_CLASS_TEXT or
            EditorInfo.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD or
            EditorInfo.TYPE_TEXT_FLAG_NO_SUGGESTIONS
        outAttrs.imeOptions = EditorInfo.IME_FLAG_NO_FULLSCREEN or
            EditorInfo.IME_FLAG_NO_EXTRACT_UI or
            EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING
        return TerminalInputConnection()
    }

    private inner class TerminalInputConnection : BaseInputConnection(this, true) {
        override fun commitText(text: CharSequence?, newCursorPosition: Int): Boolean {
            super.commitText(text, newCursorPosition)
            flushEditable()
            return true
        }

        override fun finishComposingText(): Boolean {
            super.finishComposingText()
            flushEditable()
            return true
        }

        override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
            val editable = editable
            if (editable.isNullOrEmpty()) {
                // Nada local que borrar: cada carácter es un Retroceso para el terminal.
                repeat(beforeLength) { callbacks.onKeySequence(BACKSPACE) }
                return true
            }
            return super.deleteSurroundingText(beforeLength, afterLength)
        }

        private fun flushEditable() {
            val editable = editable ?: return
            if (editable.isEmpty()) return
            clearSelection()
            callbacks.onText(editable.toString())
            editable.clear()
        }
    }

    // MARK: - Teclado físico

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        val emulator = session?.emulator ?: return super.onKeyDown(keyCode, event)
        if (event.isSystem && keyCode != KeyEvent.KEYCODE_ESCAPE) return super.onKeyDown(keyCode, event)
        clearSelection()
        if (event.action == KeyEvent.ACTION_MULTIPLE && keyCode == KeyEvent.KEYCODE_UNKNOWN) {
            event.characters?.let(callbacks::onText)
            return true
        }
        val sticky = callbacks.modifiers()
        val ctrl = event.isCtrlPressed || sticky.ctrlActive
        val leftAlt = (event.metaState and KeyEvent.META_ALT_LEFT_ON) != 0
        val alt = leftAlt || sticky.altActive
        var keyMod = 0
        if (ctrl) keyMod = keyMod or KeyHandler.KEYMOD_CTRL
        if (alt) keyMod = keyMod or KeyHandler.KEYMOD_ALT
        if (event.isShiftPressed) keyMod = keyMod or KeyHandler.KEYMOD_SHIFT
        if (event.isNumLockOn) keyMod = keyMod or KeyHandler.KEYMOD_NUM_LOCK
        if (!event.isFunctionPressed) {
            val code = KeyHandler.getCode(keyCode, keyMod, emulator.isCursorKeysApplicationMode, emulator.isKeypadApplicationMode)
            if (code != null) {
                callbacks.onKeySequence(code)
                return true
            }
        }
        // Ctrl y Alt izquierdo los aplica el codificador; Alt derecho (AltGr) compone caracteres.
        val cleared = KeyEvent.META_CTRL_MASK or KeyEvent.META_ALT_LEFT_ON or
            (if ((event.metaState and KeyEvent.META_ALT_RIGHT_ON) == 0) KeyEvent.META_ALT_ON else 0)
        val unicode = event.getUnicodeChar(event.metaState and cleared.inv())
        if (unicode == 0) return super.onKeyDown(keyCode, event)
        if ((unicode and KeyCharacterMap.COMBINING_ACCENT) != 0) {
            // Tecla muerta (p. ej. ´ en un teclado español): se combina con la siguiente.
            if (combiningAccent != 0) callbacks.onCodePoint(combiningAccent, event.isCtrlPressed, leftAlt)
            combiningAccent = unicode and KeyCharacterMap.COMBINING_ACCENT_MASK
            return true
        }
        var codePoint = unicode
        if (combiningAccent != 0) {
            val combined = KeyCharacterMap.getDeadChar(combiningAccent, unicode)
            if (combined > 0) codePoint = combined
            combiningAccent = 0
        }
        callbacks.onCodePoint(codePoint, event.isCtrlPressed, leftAlt)
        return true
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean {
        if (session == null || (event.isSystem && keyCode != KeyEvent.KEYCODE_ESCAPE)) return super.onKeyUp(keyCode, event)
        return true
    }

    // MARK: - Gestos

    private val gestures = GestureDetector(
        context,
        object : GestureDetector.SimpleOnGestureListener() {
            override fun onDown(e: MotionEvent): Boolean {
                if (!scroller.isFinished) scroller.forceFinished(true)
                scrollRemainder = 0f
                return true
            }

            override fun onSingleTapUp(e: MotionEvent): Boolean {
                if (selection != null) {
                    actionMode?.finish()
                    clearSelection()
                    return true
                }
                val emulator = session?.emulator
                if (emulator != null && emulator.isMouseTrackingActive && !e.isFromSource(InputDevice.SOURCE_MOUSE)) {
                    // Un toque es un clic para tmux (elegir panel o ventana de la barra de estado).
                    sendMouse(e, TerminalEmulator.MOUSE_LEFT_BUTTON, pressed = true)
                    sendMouse(e, TerminalEmulator.MOUSE_LEFT_BUTTON, pressed = false)
                }
                showKeyboard()
                return true
            }

            override fun onScroll(e1: MotionEvent?, e2: MotionEvent, distanceX: Float, distanceY: Float): Boolean {
                if (scaleDetector.isInProgress || selecting) return true
                val total = distanceY + scrollRemainder
                val rows = (total / renderer.fontLineSpacing).toInt()
                scrollRemainder = total - rows * renderer.fontLineSpacing
                doScroll(e2, rows)
                return true
            }

            override fun onFling(e1: MotionEvent?, e2: MotionEvent, velocityX: Float, velocityY: Float): Boolean {
                if (scaleDetector.isInProgress || selecting) return true
                startFling(e2, velocityY)
                return true
            }

            override fun onLongPress(e: MotionEvent) {
                if (scaleDetector.isInProgress) return
                performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                val cell = cellAt(e, relativeToScroll = true)
                selection = Selection(cell.first, cell.second, cell.first, cell.second)
                selecting = true
                invalidate()
            }
        },
    )

    private val scaleDetector = ScaleGestureDetector(
        context,
        object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
            override fun onScaleBegin(detector: ScaleGestureDetector): Boolean {
                pinchBaseSp = fontSizeSp
                pinchScale = 1f
                return true
            }

            override fun onScale(detector: ScaleGestureDetector): Boolean {
                pinchScale *= detector.scaleFactor
                val target = TerminalSettings.clampFontSize((pinchBaseSp * pinchScale).roundToInt())
                if (target != fontSizeSp) {
                    setFontSize(target)
                    callbacks.onFontSizeChanged(target)
                }
                return true
            }
        },
    )

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (session == null) return true
        if (event.isFromSource(InputDevice.SOURCE_MOUSE) && handleMouseButtons(event)) return true
        if (selecting) {
            when (event.actionMasked) {
                MotionEvent.ACTION_MOVE -> extendSelection(event)
                MotionEvent.ACTION_UP -> finishSelection()
                MotionEvent.ACTION_CANCEL -> clearSelection()
            }
            return true
        }
        scaleDetector.onTouchEvent(event)
        gestures.onTouchEvent(event)
        return true
    }

    override fun onGenericMotionEvent(event: MotionEvent): Boolean {
        if (session != null && event.isFromSource(InputDevice.SOURCE_CLASS_POINTER) && event.actionMasked == MotionEvent.ACTION_SCROLL) {
            val up = event.getAxisValue(MotionEvent.AXIS_VSCROLL) > 0f
            doScroll(event, if (up) -WHEEL_ROWS else WHEEL_ROWS)
            return true
        }
        return super.onGenericMotionEvent(event)
    }

    /** Ratón/trackpad: clic derecho o central pega; con tmux siguiendo el ratón, se le reenvía. */
    private fun handleMouseButtons(event: MotionEvent): Boolean {
        if (event.isButtonPressed(MotionEvent.BUTTON_SECONDARY) || event.isButtonPressed(MotionEvent.BUTTON_TERTIARY)) {
            if (event.actionMasked == MotionEvent.ACTION_DOWN) pasteFromClipboard()
            return true
        }
        val emulator = session?.emulator ?: return false
        if (!emulator.isMouseTrackingActive) return false
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> sendMouse(event, TerminalEmulator.MOUSE_LEFT_BUTTON, pressed = true)
            MotionEvent.ACTION_MOVE -> sendMouse(event, TerminalEmulator.MOUSE_LEFT_BUTTON_MOVED, pressed = true)
            MotionEvent.ACTION_UP -> sendMouse(event, TerminalEmulator.MOUSE_LEFT_BUTTON, pressed = false)
        }
        requestFocus()
        return true
    }

    private fun doScroll(event: MotionEvent, rowsDown: Int) {
        val emulator = session?.emulator ?: return
        val up = rowsDown < 0
        repeat(abs(rowsDown)) {
            when {
                emulator.isMouseTrackingActive ->
                    sendMouse(event, if (up) TerminalEmulator.MOUSE_WHEELUP_BUTTON else TerminalEmulator.MOUSE_WHEELDOWN_BUTTON, pressed = true)
                emulator.isAlternateBufferActive -> {
                    val keyCode = if (up) KeyEvent.KEYCODE_DPAD_UP else KeyEvent.KEYCODE_DPAD_DOWN
                    KeyHandler.getCode(keyCode, 0, emulator.isCursorKeysApplicationMode, emulator.isKeypadApplicationMode)
                        ?.let(callbacks::onKeySequence)
                }
                else -> {
                    topRow = (topRow + if (up) -1 else 1).coerceIn(-emulator.screen.activeTranscriptRows, 0)
                    if (!awakenScrollBars()) invalidate()
                }
            }
        }
    }

    private fun startFling(event: MotionEvent, velocityY: Float) {
        val emulator = session?.emulator ?: return
        val mouse = emulator.isMouseTrackingActive
        val velocity = -(velocityY * FLING_SCALE).toInt()
        if (mouse) {
            scroller.fling(0, 0, 0, velocity, 0, 0, -emulator.mRows / 2, emulator.mRows / 2)
        } else {
            scroller.fling(0, topRow, 0, velocity, 0, 0, -emulator.screen.activeTranscriptRows, 0)
        }
        val origin = MotionEvent.obtain(event)
        post(object : Runnable {
            private var lastY = 0

            override fun run() {
                val current = session?.emulator
                if (current == null || current.isMouseTrackingActive != mouse || scroller.isFinished) {
                    origin.recycle()
                    return
                }
                val more = scroller.computeScrollOffset()
                val y = scroller.currY
                doScroll(origin, if (mouse) y - lastY else y - topRow)
                lastY = y
                if (more) post(this) else origin.recycle()
            }
        })
    }

    private fun sendMouse(event: MotionEvent, button: Int, pressed: Boolean) {
        val emulator = session?.emulator ?: return
        val (column, row) = cellAt(event, relativeToScroll = false)
        emulator.sendMouseEvent(button, column + 1, row + 1, pressed)
    }

    private fun cellAt(event: MotionEvent, relativeToScroll: Boolean): Pair<Int, Int> {
        val emulator = session?.emulator
        val maxColumn = (emulator?.mColumns ?: 1) - 1
        val column = (event.x / renderer.fontWidth).toInt().coerceIn(0, max(0, maxColumn))
        val row = ((event.y - lineSpacingAndAscent) / renderer.fontLineSpacing).toInt().coerceAtLeast(0)
        return column to if (relativeToScroll) row + topRow else row
    }

    // MARK: - Selección y copia

    private data class Selection(val anchorColumn: Int, val anchorRow: Int, val column: Int, val row: Int) {
        fun normalized(): Range {
            val anchorFirst = anchorRow < row || (anchorRow == row && anchorColumn <= column)
            return if (anchorFirst) Range(anchorRow, anchorColumn, row, column) else Range(row, column, anchorRow, anchorColumn)
        }

        fun shifted(rows: Int) = copy(anchorRow = anchorRow + rows, row = row + rows)
    }

    private data class Range(val startRow: Int, val startColumn: Int, val endRow: Int, val endColumn: Int)

    private fun extendSelection(event: MotionEvent) {
        val current = selection ?: return
        val (column, row) = cellAt(event, relativeToScroll = true)
        selection = current.copy(column = column, row = row)
        invalidate()
    }

    private fun finishSelection() {
        selecting = false
        if (selection == null) return
        actionMode = startActionMode(SelectionActionMode(), ActionMode.TYPE_FLOATING)
    }

    private fun clearSelection() {
        selecting = false
        if (selection == null) return
        selection = null
        actionMode?.finish()
        invalidate()
    }

    private fun selectedText(): String? {
        val emulator = session?.emulator ?: return null
        val range = selection?.normalized() ?: return null
        return emulator.getSelectedText(range.startColumn, range.startRow, range.endColumn, range.endRow)
    }

    /**
     * Copia pedida por el SERVIDOR (OSC 52, `set-clipboard` de tmux). El contenido es remoto y
     * no fiable: solo se acepta mientras el usuario está mirando el terminal (ventana con
     * foco) y con un tope de tamaño; nunca se lee el portapapeles hacia el servidor.
     */
    private fun copyFromRemote(text: String) {
        if (!hasWindowFocus() || text.length > MAX_REMOTE_CLIP_CHARS) return
        copyToClipboard(text)
    }

    private fun copyToClipboard(text: String) {
        val clipboard = context.getSystemService(ClipboardManager::class.java) ?: return
        clipboard.setPrimaryClip(ClipData.newPlainText(context.getString(R.string.terminal_clip_label), text))
    }

    private inner class SelectionActionMode : ActionMode.Callback2() {
        override fun onCreateActionMode(mode: ActionMode, menu: Menu): Boolean {
            menu.add(Menu.NONE, MENU_COPY, 0, R.string.terminal_copy)
            menu.add(Menu.NONE, MENU_PASTE, 1, R.string.terminal_paste)
            return true
        }

        override fun onPrepareActionMode(mode: ActionMode, menu: Menu): Boolean = false

        override fun onActionItemClicked(mode: ActionMode, item: MenuItem): Boolean {
            when (item.itemId) {
                MENU_COPY -> selectedText()?.takeIf { it.isNotEmpty() }?.let(::copyToClipboard)
                MENU_PASTE -> pasteFromClipboard()
                else -> return false
            }
            mode.finish()
            return true
        }

        override fun onDestroyActionMode(mode: ActionMode) {
            actionMode = null
            selection = null
            invalidate()
        }

        override fun onGetContentRect(mode: ActionMode, view: View, outRect: Rect) {
            val range = selection?.normalized()
            if (range == null) {
                outRect.set(0, 0, width, height)
                return
            }
            val top = ((range.startRow - topRow) * renderer.fontLineSpacing).coerceIn(0, height)
            val bottom = ((range.endRow - topRow + 1) * renderer.fontLineSpacing + lineSpacingAndAscent).coerceIn(top, height)
            outRect.set(0, top, width, bottom)
        }
    }

    // MARK: - Utilidades

    private fun spToPx(sp: Int): Int =
        TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, sp.toFloat(), resources.displayMetrics).roundToInt()

    /** Igual que `TerminalRenderer.mFontLineSpacingAndAscent` (no es público). */
    private fun lineSpacingAndAscent(sp: Int): Int {
        val paint = Paint().apply {
            typeface = Typeface.MONOSPACE
            textSize = spToPx(sp).toFloat()
        }
        return ceil(paint.fontSpacing).toInt() + ceil(paint.ascent()).toInt()
    }

    private companion object {
        const val BACKGROUND = 0xFF000000.toInt()
        const val MIN_GRID = 4
        const val WHEEL_ROWS = 3
        const val FLING_SCALE = 0.25f
        const val MENU_COPY = 1
        const val MENU_PASTE = 2

        /** Tope de una copia OSC 52 (el portapapeles de Android ronda 1 MB por transacción). */
        const val MAX_REMOTE_CLIP_CHARS = 256 * 1024
        const val BACKSPACE = "\u007F"
    }
}
