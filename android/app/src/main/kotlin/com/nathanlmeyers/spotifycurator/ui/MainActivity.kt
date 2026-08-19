package com.nathanlmeyers.spotifycurator.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings as AndroidSettings
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.nathanlmeyers.spotifycurator.curation.CurationEngine
import com.nathanlmeyers.spotifycurator.media.NotificationAccessStub
import com.nathanlmeyers.spotifycurator.service.CuratorService
import com.nathanlmeyers.spotifycurator.state.Settings
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {

    override fun onStart() {
        super.onStart()
        // Resume the service if the switch is on — after an app update, a crash, or a
        // low-memory kill. An Activity coming to the foreground is an allowed reason to start a
        // foreground service, which is why this lives here and not in CuratorApp.
        CuratorService.sync(this)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme(colorScheme = darkColorScheme()) {
                Surface(Modifier.fillMaxSize()) { CuratorScreen() }
            }
        }
    }
}

@Composable
private fun CuratorScreen() {
    val context = LocalContext.current
    val engine = remember { CurationEngine.get(context) }
    val settings = engine.settings
    val state by engine.state.collectAsStateWithLifecycle()
    val auth by engine.auth.state.collectAsStateWithLifecycle()

    // Every settings write bumps this. Read every preference through `pref` so that bump is
    // actually *read* during composition: `settings.*` are plain SharedPreferences reads, which
    // Compose can't observe, and a `by` delegate nothing touches records no dependency at all —
    // so a write left the switches, the radio selection and the checklist on their old values
    // until some unrelated state happened to recompose the screen.
    val revision by settings.revision.collectAsStateWithLifecycle()
    fun <T> pref(read: Settings.() -> T): T = revision.let { settings.read() }

    // Engine-held, so the list outlives this Activity: a target picked once stays picked.
    val playlists by engine.playlists.collectAsStateWithLifecycle()
    var loadingPlaylists by remember { mutableStateOf(false) }
    var playlistError by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    // The special-access grants are made in *system* Settings, so nothing in this app changes
    // when they're granted — no preference write, no recomposition. The only reliable moment to
    // re-read them is when this screen comes back to the foreground.
    var notificationAccess by remember { mutableStateOf(false) }
    var notificationsAllowed by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED
        )
    }
    var ignoringBattery by remember { mutableStateOf(false) }
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                notificationAccess = NotificationAccessStub.isGranted(context)
                notificationsAllowed = ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.POST_NOTIFICATIONS,
                ) == PackageManager.PERMISSION_GRANTED
                ignoringBattery = context.getSystemService(PowerManager::class.java)
                    .isIgnoringBatteryOptimizations(context.packageName)
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    val postNotifications = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        notificationsAllowed = granted
        if (granted) CuratorService.sync(context)
    }

    LaunchedEffect(auth.isAuthorized, pref { targetPlaylistId }) {
        if (auth.isAuthorized) engine.loadTargetMembership()
    }

    // Fill the picker without being asked, the way the Mac's panel does on open
    // (`AppDelegate`: `if isAuthorized && editablePlaylists.isEmpty { loadPlaylists() }`).
    // Until this existed, the list was empty at every launch, so no target ever got picked and
    // Add had nowhere to add to.
    LaunchedEffect(auth.isAuthorized) {
        if (auth.isAuthorized) engine.loadPlaylists()
    }

    Scaffold { padding ->
        Column(
            Modifier
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text("Spotify Curator", style = MaterialTheme.typography.headlineSmall)

            // MARK: Master switch
            Card {
                Column(Modifier.padding(16.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text("Curator on", fontWeight = FontWeight.Medium)
                            Text(
                                "Keeps Add / Remove / Skip on the lock screen the whole time you're listening.",
                                style = MaterialTheme.typography.bodySmall,
                            )
                        }
                        Switch(
                            checked = pref { curatorEnabled },
                            onCheckedChange = {
                                settings.curatorEnabled = it
                                if (it && !notificationsAllowed) {
                                    postNotifications.launch(Manifest.permission.POST_NOTIFICATIONS)
                                }
                                CuratorService.sync(context)
                            },
                        )
                    }
                }
            }

            // MARK: Setup checklist
            Card {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("Setup", fontWeight = FontWeight.Medium)

                    ChecklistRow(
                        label = "Spotify account",
                        done = auth.isAuthorized,
                        detail = if (auth.isAuthorized) "Logged in" else "Needed to edit playlists",
                        actionLabel = if (auth.isAuthorized) "Log out" else "Log in",
                        onAction = {
                            if (auth.isAuthorized) engine.logout() else engine.auth.beginLogin(context)
                        },
                    )

                    ChecklistRow(
                        label = "Notification access",
                        done = notificationAccess,
                        detail = "Lets the app read Spotify's media session — how it knows what's playing",
                        actionLabel = "Grant",
                        onAction = {
                            context.startActivity(
                                Intent(AndroidSettings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
                            )
                        },
                    )

                    ChecklistRow(
                        label = "Lock-screen controls",
                        done = notificationsAllowed,
                        detail = if (notificationsAllowed) {
                            "Notifications allowed"
                        } else {
                            "Required to show Add / Remove / Skip on the lock screen"
                        },
                        actionLabel = if (notificationsAllowed) "Allowed" else "Allow",
                        onAction = {
                            if (!notificationsAllowed) {
                                postNotifications.launch(Manifest.permission.POST_NOTIFICATIONS)
                            }
                        },
                    )

                    // Listed here because Add is dead without it, and nothing else about the app
                    // looks broken when it's missing: Remove works off the playing context, so the
                    // only symptom is that + silently refuses.
                    ChecklistRow(
                        label = "Target playlist",
                        done = pref { targetPlaylistId } != null,
                        detail = pref { targetPlaylistName }
                            ?: "Where Add (+) puts songs — Add can't work without it",
                        actionLabel = "Choose",
                        onAction = {
                            loadingPlaylists = true
                            playlistError = null
                            scope.launch {
                                engine.loadPlaylists(force = true)
                                loadingPlaylists = false
                            }
                        },
                    )

                    ChecklistRow(
                        label = "Unrestricted battery",
                        done = ignoringBattery,
                        detail = "Stops Android suspending the curator during a long listen",
                        actionLabel = "Allow",
                        onAction = {
                            context.startActivity(
                                Intent(
                                    AndroidSettings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                    Uri.parse("package:${context.packageName}"),
                                )
                            )
                        },
                    )

                    auth.lastError?.let {
                        Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
                    }
                    if (auth.isAuthorized && !auth.hasLibraryScopes) {
                        Text(
                            "This login predates some permissions. Log out and back in when convenient — " +
                                "a token refresh can't widen them.",
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                }
            }

            // MARK: Target playlist
            Card {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text("Add to", fontWeight = FontWeight.Medium)
                            Text(
                                pref { targetPlaylistName } ?: "No playlist chosen",
                                style = MaterialTheme.typography.bodySmall,
                            )
                        }
                        TextButton(
                            enabled = auth.isAuthorized && !loadingPlaylists,
                            onClick = {
                                loadingPlaylists = true
                                playlistError = null
                                scope.launch {
                                    engine.loadPlaylists(force = true)
                                        .onFailure { playlistError = it.message }
                                    loadingPlaylists = false
                                }
                            },
                        ) { Text(if (playlists.isEmpty()) "Load playlists" else "Reload") }
                    }

                    if (loadingPlaylists) CircularProgressIndicator(Modifier.width(24.dp))
                    playlistError?.let {
                        Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
                    }

                    // Only playlists you can actually write to — the same filter the Mac applies.
                    playlists.forEach { playlist ->
                        Row(
                            Modifier
                                .fillMaxWidth()
                                .selectable(
                                    selected = pref { targetPlaylistId } == playlist.id,
                                    onClick = {
                                        settings.targetPlaylistId = playlist.id
                                        settings.targetPlaylistName = playlist.name
                                        scope.launch { engine.loadTargetMembership() }
                                    },
                                ),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            RadioButton(selected = pref { targetPlaylistId } == playlist.id, onClick = null)
                            Spacer(Modifier.width(8.dp))
                            Text(playlist.name)
                        }
                    }
                }
            }

            // MARK: Behaviour
            Card {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("Behaviour", fontWeight = FontWeight.Medium)
                    ToggleRow(
                        "Move on add",
                        "Also remove from the playlist you're listening to",
                        pref { removeFromSourceOnAdd },
                    ) { settings.removeFromSourceOnAdd = it }
                    ToggleRow("Skip to next after Add", null, pref { skipToNextAfterAdd }) {
                        settings.skipToNextAfterAdd = it
                    }
                    ToggleRow("Skip to next after Remove", null, pref { skipToNextAfterRemove }) {
                        settings.skipToNextAfterRemove = it
                    }
                }
            }

            // MARK: Discovery
            Card {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("Discovery mode", fontWeight = FontWeight.Medium)
                    ToggleRow(
                        "Hold at the end of each track",
                        "Pauses just before a song ends so you can add, remove, or skip it",
                        pref { discoveryEnabled },
                    ) { engine.setDiscoveryEnabled(it) }
                    if (pref { discoveryEnabled }) {
                        ToggleRow("Vibrate on hold", null, pref { alertSound }) {
                            settings.alertSound = it
                        }
                        ToggleRow(
                            "Auto-skip if already in ${pref { targetPlaylistName } ?: "target"}",
                            null,
                            pref { skipIfInTarget },
                        ) { settings.skipIfInTarget = it }
                        ToggleRow(
                            "Auto-skip already-reviewed tracks",
                            null,
                            pref { skipAlreadyReviewed },
                        ) { settings.skipAlreadyReviewed = it }
                        Text(
                            "Auto-skip only skips. Nothing is ever removed from a playlist without " +
                                "you pressing Remove.",
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                }
            }

            // MARK: Now playing
            Card {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("Now playing", fontWeight = FontWeight.Medium)
                    val np = state.nowPlaying
                    if (np == null) {
                        Text(
                            if (notificationAccess) "Nothing playing" else "Grant notification access to see this",
                            style = MaterialTheme.typography.bodySmall,
                        )
                    } else {
                        Text(np.name)
                        Text(np.artist, style = MaterialTheme.typography.bodySmall)
                        HorizontalDivider(Modifier.padding(vertical = 8.dp))
                        Text(
                            state.source.playlistName?.let { "From $it" } ?: "Not playing from a playlist",
                            style = MaterialTheme.typography.bodySmall,
                        )
                        if (state.inTarget) {
                            Text(
                                "Already in ${pref { targetPlaylistName } ?: "target"}",
                                style = MaterialTheme.typography.bodySmall,
                            )
                        }
                    }
                    state.status?.let {
                        Text(
                            it,
                            style = MaterialTheme.typography.bodySmall,
                            color = if (state.isError) MaterialTheme.colorScheme.error
                            else MaterialTheme.colorScheme.onSurface,
                        )
                    }
                    Row(Modifier.padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Button(onClick = { engine.onAddPressed() }, enabled = !state.isBusy) { Text("Add") }
                        Button(
                            onClick = { engine.onRemovePressed() },
                            enabled = !state.isBusy && state.source.isEditablePlaylist,
                        ) { Text("Remove") }
                        Button(onClick = { engine.onSkipPressed() }) { Text("Skip") }
                    }
                }
            }
        }
    }
}

@Composable
private fun ChecklistRow(
    label: String,
    done: Boolean,
    detail: String,
    actionLabel: String,
    onAction: () -> Unit,
) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(if (done) "✓" else "•", Modifier.width(24.dp))
        Column(Modifier.weight(1f)) {
            Text(label)
            Text(detail, style = MaterialTheme.typography.bodySmall)
        }
        TextButton(onClick = onAction) { Text(actionLabel) }
    }
}

@Composable
private fun ToggleRow(label: String, detail: String?, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(label)
            detail?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
        }
        Switch(checked = checked, onCheckedChange = onChange)
    }
}
