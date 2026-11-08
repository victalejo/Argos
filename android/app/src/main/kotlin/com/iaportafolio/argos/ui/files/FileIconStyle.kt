package com.iaportafolio.argos.ui.files

import androidx.annotation.DrawableRes
import androidx.compose.ui.graphics.Color
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.files.FileIcon
import com.iaportafolio.argos.core.files.FileIconTint

/** Dibujo por categoría de [FileIcon] (sustituye a los SF Symbols de Apple). */
@DrawableRes
internal fun FileIcon.drawable(): Int = when (this) {
    FileIcon.SYMLINK -> R.drawable.ic_link
    FileIcon.IMAGE -> R.drawable.ic_image
    FileIcon.PDF -> R.drawable.ic_pdf
    FileIcon.ARCHIVE -> R.drawable.ic_archive
    FileIcon.MEDIA -> R.drawable.ic_media
    FileIcon.DATABASE_FILE -> R.drawable.ic_database
    FileIcon.MARKDOWN, FileIcon.README, FileIcon.LICENSE, FileIcon.TEXT, FileIcon.AGENT_INSTRUCTIONS -> R.drawable.ic_file_text
    FileIcon.SWIFT, FileIcon.TYPESCRIPT, FileIcon.JAVASCRIPT, FileIcon.PYTHON, FileIcon.GO, FileIcon.RUST,
    FileIcon.OTHER_CODE, FileIcon.HTML, FileIcon.STYLESHEET, FileIcon.JSON, FileIcon.SHELL, FileIcon.DOCKER,
    FileIcon.MAKEFILE, FileIcon.PACKAGE_MANIFEST,
    -> R.drawable.ic_code
    FileIcon.LOCKFILE, FileIcon.GITIGNORE, FileIcon.CONFIG_FILE, FileIcon.ENV, FileIcon.GENERIC_FILE -> R.drawable.ic_file
    else -> if (name.endsWith("_FOLDER")) R.drawable.ic_folder else R.drawable.ic_file
}

/** Color de cada tono semántico (paleta de sistema de Apple, legible en claro y oscuro). */
internal fun FileIconTint.color(): Color = when (this) {
    FileIconTint.BLUE -> Color(0xFF0A84FF)
    FileIconTint.ORANGE -> Color(0xFFFF9F0A)
    FileIconTint.YELLOW -> Color(0xFFE6B800)
    FileIconTint.GREEN -> Color(0xFF30B94D)
    FileIconTint.MINT -> Color(0xFF00C7BE)
    FileIconTint.TEAL -> Color(0xFF30B0C7)
    FileIconTint.PURPLE -> Color(0xFFBF5AF2)
    FileIconTint.PINK -> Color(0xFFFF375F)
    FileIconTint.RED -> Color(0xFFFF453A)
    FileIconTint.GRAY -> Color(0xFF8E8E93)
    FileIconTint.BROWN -> Color(0xFFAC8E68)
    FileIconTint.INDIGO -> Color(0xFF5E5CE6)
}
