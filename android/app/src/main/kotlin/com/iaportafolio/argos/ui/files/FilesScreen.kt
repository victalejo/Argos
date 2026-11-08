package com.iaportafolio.argos.ui.files

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.text.format.DateUtils
import android.text.format.Formatter
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconToggleButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.VerticalDivider
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import kotlinx.coroutines.delay
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.files.FileDownloadStatus
import com.iaportafolio.argos.core.files.FileIcon
import com.iaportafolio.argos.core.files.RemoteFileEntry
import com.iaportafolio.argos.ui.common.MessageEffect
import com.iaportafolio.argos.ui.common.ProgressMessage
import com.iaportafolio.argos.ui.common.StatusMessage
import com.iaportafolio.argos.ui.common.asString

/**
 * Explorador de archivos del proyecto (equivale a `RemoteFilesView` de iOS). En móvil, una
 * pantalla a la vez (carpeta o vista previa); con [twoPane], carpeta | vista previa.
 * [onExit] sale del explorador cuando «atrás» ya no tiene nada que cerrar.
 */
@Composable
fun FilesScreen(viewModel: RemoteFilesViewModel, twoPane: Boolean, onExit: () -> Unit, modifier: Modifier = Modifier) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val snackbar = remember { SnackbarHostState() }
    MessageEffect(state.message, snackbar, viewModel::messageShown)

    var pendingRequest by remember { mutableStateOf<DownloadRequest?>(null) }
    val saveLauncher = rememberLauncherForActivityResult(CreateDocumentContract()) { uri ->
        pendingRequest?.let { viewModel.onDownloadDestination(it, uri?.toString()) }
        pendingRequest = null
    }
    LaunchedEffect(viewModel) {
        viewModel.events.collect { event ->
            when (event) {
                is FilesEvent.ChooseDownloadDestination -> {
                    pendingRequest = event.request
                    saveLauncher.launch(event.request)
                }
            }
        }
    }
    val clipLabel = stringResource(R.string.files_path_clip_label)
    val copyPath = { path: String ->
        copyToClipboard(context, clipLabel, path)
        viewModel.onPathCopied()
    }
    val back = { if (!viewModel.back()) onExit() }
    BackHandler(enabled = state.preview != null || state.search.isActive || !state.isAtRoot) { viewModel.back() }

    Scaffold(modifier = modifier, snackbarHost = { SnackbarHost(snackbar) }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            Box(Modifier.weight(1f)) {
                val preview = state.preview
                when {
                    twoPane -> Row(Modifier.fillMaxSize()) {
                        BrowserPane(state, viewModel, back, copyPath, Modifier.width(BROWSER_PANE_WIDTH).fillMaxHeight())
                        VerticalDivider()
                        if (preview == null) {
                            StatusMessage(icon = painterResource(R.drawable.ic_file), title = stringResource(R.string.files_pick))
                        } else {
                            FilePreviewPane(preview, viewModel, onClose = viewModel::closePreview, onCopyPath = copyPath, showClose = true)
                        }
                    }
                    preview != null -> FilePreviewPane(preview, viewModel, onClose = viewModel::closePreview, onCopyPath = copyPath, showClose = false)
                    else -> BrowserPane(state, viewModel, back, copyPath, Modifier.fillMaxSize())
                }
            }
            state.download?.let { download ->
                if (download.status is FileDownloadStatus.Saved) {
                    LaunchedEffect(download) {
                        delay(DOWNLOAD_BANNER_MILLIS)
                        viewModel.dismissDownload()
                    }
                }
                DownloadBanner(download, viewModel::cancelDownload, viewModel::dismissDownload)
            }
        }
    }
}

private val BROWSER_PANE_WIDTH = 380.dp

/** El aviso de «guardado» se cierra solo; los errores se quedan hasta cerrarlos. */
private const val DOWNLOAD_BANNER_MILLIS = 4_000L

/** Lista de la carpeta (o resultados de búsqueda) con su barra y las migas de pan. */
@Composable
private fun BrowserPane(
    state: FilesUiState,
    viewModel: RemoteFilesViewModel,
    onBack: () -> Unit,
    onCopyPath: (String) -> Unit,
    modifier: Modifier,
) {
    Column(modifier) {
        if (state.search.isActive) {
            SearchBar(state.search, viewModel)
        } else {
            BrowserTopBar(state, viewModel, onBack)
            Breadcrumbs(state.breadcrumbs, onOpen = viewModel::open)
        }
        HorizontalDivider()
        Box(Modifier.weight(1f)) {
            if (state.search.isActive) {
                SearchResults(state.search, viewModel)
            } else {
                DirectoryContent(state, viewModel, onCopyPath)
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun BrowserTopBar(state: FilesUiState, viewModel: RemoteFilesViewModel, onBack: () -> Unit) {
    TopAppBar(
        // El Scaffold de la pantalla ya aplica el inset de la barra de estado.
        windowInsets = WindowInsets(0),
        title = {
            Text(
                if (state.isAtRoot) stringResource(R.string.project_tab_files) else state.breadcrumbs.last().label,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        },
        navigationIcon = {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.action_back))
            }
        },
        actions = {
            IconButton(onClick = viewModel::openSearch) {
                Icon(Icons.Filled.Search, contentDescription = stringResource(R.string.files_search))
            }
            IconToggleButton(checked = state.showHidden, onCheckedChange = viewModel::setShowHidden) {
                Icon(
                    painterResource(R.drawable.ic_visibility),
                    contentDescription = stringResource(R.string.files_show_hidden),
                    tint = if (state.showHidden) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        },
    )
}

@Composable
private fun Breadcrumbs(crumbs: List<Breadcrumb>, onOpen: (String) -> Unit) {
    val listState = rememberLazyListState()
    // La carpeta actual (la última miga) siempre a la vista.
    LaunchedEffect(crumbs.size) { listState.scrollToItem(crumbs.lastIndex) }
    LazyRow(state = listState, modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        itemsIndexed(crumbs, key = { _, crumb -> crumb.path }) { index, crumb ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (index > 0) {
                    Icon(
                        Icons.AutoMirrored.Filled.KeyboardArrowRight,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                val isCurrent = index == crumbs.lastIndex
                TextButton(onClick = { onOpen(crumb.path) }, enabled = !isCurrent) {
                    Text(crumb.label, maxLines = 1)
                }
            }
        }
    }
}

@Composable
private fun DirectoryContent(state: FilesUiState, viewModel: RemoteFilesViewModel, onCopyPath: (String) -> Unit) {
    when (val load = state.load) {
        DirectoryLoad.Loading -> ProgressMessage(stringResource(R.string.files_loading))
        is DirectoryLoad.Failed -> StatusMessage(
            icon = rememberVectorPainter(Icons.Filled.Warning),
            title = stringResource(R.string.files_failed_title),
            body = load.message.asString(),
        ) { Button(onClick = { viewModel.open(state.path) }) { Text(stringResource(R.string.action_retry)) } }
        DirectoryLoad.Loaded -> PullToRefreshBox(isRefreshing = state.isRefreshing, onRefresh = viewModel::refresh, modifier = Modifier.fillMaxSize()) {
            LazyColumn(Modifier.fillMaxSize()) {
                if (state.visibleEntries.isEmpty()) {
                    item {
                        StatusMessage(
                            icon = painterResource(R.drawable.ic_folder_open),
                            title = stringResource(R.string.files_empty),
                            body = if (state.hiddenCount > 0) {
                                pluralStringResource(R.plurals.files_hidden_count, state.hiddenCount, state.hiddenCount)
                            } else {
                                null
                            },
                            modifier = Modifier.fillParentMaxSize(),
                        )
                    }
                }
                items(state.visibleEntries, key = { it.id }) { entry ->
                    FileRow(entry, onOpen = { viewModel.openEntry(entry) }, viewModel = viewModel, onCopyPath = onCopyPath)
                }
                if (state.visibleEntries.isNotEmpty() && state.hiddenCount > 0) {
                    item(key = "hidden-footer") {
                        TextButton(onClick = { viewModel.setShowHidden(true) }, modifier = Modifier.padding(8.dp)) {
                            Text(pluralStringResource(R.plurals.files_hidden_count, state.hiddenCount, state.hiddenCount))
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun FileRow(entry: RemoteFileEntry, onOpen: () -> Unit, viewModel: RemoteFilesViewModel, onCopyPath: (String) -> Unit) {
    val context = LocalContext.current
    val icon = FileIcon.of(entry)
    var menuOpen by remember { mutableStateOf(false) }
    val detail = remember(entry) { entryDetail(context, entry) }
    ListItem(
        modifier = Modifier.clickable(role = Role.Button, onClick = onOpen),
        leadingContent = { Icon(painterResource(icon.drawable()), contentDescription = null, tint = icon.tint.color()) },
        headlineContent = { Text(entry.name, maxLines = 1, overflow = TextOverflow.MiddleEllipsis) },
        supportingContent = detail?.let { { Text(it) } },
        trailingContent = {
            Box {
                IconButton(onClick = { menuOpen = true }) {
                    Icon(Icons.Filled.MoreVert, contentDescription = stringResource(R.string.files_more_for, entry.name))
                }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    if (!entry.isDirectory) {
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.files_download)) },
                            leadingIcon = { Icon(painterResource(R.drawable.ic_download), contentDescription = null) },
                            onClick = { menuOpen = false; viewModel.requestDownload(entry.path, entry.name, entry.size) },
                        )
                    }
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.files_copy_path)) },
                        leadingIcon = { Icon(painterResource(R.drawable.ic_copy), contentDescription = null) },
                        onClick = { menuOpen = false; onCopyPath(entry.path) },
                    )
                }
            }
        },
    )
}

/** «12 KB · hace 3 días» (tamaño solo en archivos). */
private fun entryDetail(context: Context, entry: RemoteFileEntry): String? {
    val parts = buildList {
        if (!entry.isDirectory) entry.size?.let { add(Formatter.formatShortFileSize(context, it)) }
        entry.modified?.let { add(DateUtils.getRelativeTimeSpanString(it.toEpochMilli()).toString()) }
    }
    return parts.takeIf { it.isNotEmpty() }?.joinToString(" · ")
}

@Composable
private fun SearchBar(search: FileSearchState, viewModel: RemoteFilesViewModel) {
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { focus.requestFocus() }
    Row(Modifier.fillMaxWidth().padding(4.dp), verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = viewModel::closeSearch) {
            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.files_search_close))
        }
        TextField(
            value = search.query,
            onValueChange = viewModel::onSearchQuery,
            placeholder = { Text(stringResource(R.string.files_search_hint)) },
            singleLine = true,
            keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, imeAction = ImeAction.Search),
            modifier = Modifier.weight(1f).focusRequester(focus),
            trailingIcon = {
                if (search.query.isNotEmpty()) {
                    IconButton(onClick = { viewModel.onSearchQuery("") }) {
                        Icon(Icons.Filled.Close, contentDescription = stringResource(R.string.files_search_clear))
                    }
                }
            },
        )
    }
}

@Composable
private fun SearchResults(search: FileSearchState, viewModel: RemoteFilesViewModel) {
    val error = search.error
    when {
        search.isIndexing -> ProgressMessage(stringResource(R.string.files_indexing))
        error != null -> StatusMessage(
            icon = rememberVectorPainter(Icons.Filled.Warning),
            title = stringResource(R.string.files_index_failed),
            body = error.asString(),
        ) { Button(onClick = viewModel::retryIndex) { Text(stringResource(R.string.action_retry)) } }
        search.query.isBlank() -> StatusMessage(icon = rememberVectorPainter(Icons.Filled.Search), title = stringResource(R.string.files_search_prompt))
        search.results.isEmpty() -> StatusMessage(icon = rememberVectorPainter(Icons.Filled.Search), title = stringResource(R.string.files_search_empty))
        else -> LazyColumn(Modifier.fillMaxSize()) {
            items(search.results, key = { it }) { relative ->
                val name = relative.substringAfterLast('/')
                val icon = FileIcon.file(name)
                ListItem(
                    modifier = Modifier.clickable(role = Role.Button) { viewModel.openSearchResult(relative) },
                    leadingContent = { Icon(painterResource(icon.drawable()), contentDescription = null, tint = icon.tint.color()) },
                    headlineContent = { Text(name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                    supportingContent = { Text(relative, maxLines = 1, overflow = TextOverflow.MiddleEllipsis) },
                )
            }
        }
    }
}

/** Banner de descarga: progreso y cancelar mientras corre; resultado y cerrar al terminar. */
@Composable
private fun DownloadBanner(download: DownloadState, onCancel: () -> Unit, onDismiss: () -> Unit) {
    val context = LocalContext.current
    Surface(color = MaterialTheme.colorScheme.surfaceContainerHigh, modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp).semantics { liveRegion = LiveRegionMode.Polite }) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                val text = when (val status = download.status) {
                    is FileDownloadStatus.Downloading -> {
                        val written = Formatter.formatShortFileSize(context, download.bytesWritten)
                        val total = download.totalBytes?.let { Formatter.formatShortFileSize(context, it) }
                        if (total == null) {
                            stringResource(R.string.files_downloading, status.name, written)
                        } else {
                            stringResource(R.string.files_downloading_of, status.name, written, total)
                        }
                    }
                    is FileDownloadStatus.Saved -> stringResource(R.string.files_download_saved, download.name)
                    is FileDownloadStatus.Failed -> stringResource(R.string.files_download_failed, status.name, status.message)
                }
                Text(text, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
                if (download.status is FileDownloadStatus.Downloading) {
                    TextButton(onClick = onCancel) { Text(stringResource(R.string.action_cancel)) }
                } else {
                    IconButton(onClick = onDismiss) {
                        Icon(Icons.Filled.Close, contentDescription = stringResource(R.string.files_download_dismiss))
                    }
                }
            }
            if (download.status is FileDownloadStatus.Downloading) {
                val fraction = download.fraction
                val description = stringResource(R.string.files_download_progress)
                if (fraction == null) {
                    LinearProgressIndicator(Modifier.fillMaxWidth().semantics { contentDescription = description })
                } else {
                    LinearProgressIndicator(progress = { fraction }, modifier = Modifier.fillMaxWidth().semantics { contentDescription = description })
                }
            }
        }
    }
}

internal fun copyToClipboard(context: Context, label: String, text: String) {
    val clipboard = context.getSystemService(ClipboardManager::class.java) ?: return
    clipboard.setPrimaryClip(ClipData.newPlainText(label, text))
}
