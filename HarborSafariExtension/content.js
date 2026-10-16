// Hands download link clicks to Harbor. Hold Option while clicking to let Safari download instead.

// Path extensions that count as downloads. Edit this list to change what gets intercepted.
const DOWNLOAD_EXTENSIONS = [
    "dmg", "pkg", "zip", "7z", "rar", "tar", "gz", "iso", "exe", "msi", "apk",
    "mp4", "mkv", "mov", "mp3", "flac", "pdf", "torrent",
];

// Settings are cached so the click handler stays synchronous: Safari only lets a page open
// another app while the click's user activation is still alive, and an await would end it.
let settings = DEFAULT_SETTINGS;
browser.storage.local.get(DEFAULT_SETTINGS).then((stored) => { settings = stored; });
browser.storage.onChanged.addListener((changes) => {
    for (const [key, { newValue }] of Object.entries(changes)) {
        settings = { ...settings, [key]: newValue ?? DEFAULT_SETTINGS[key] };
    }
});

function isDownloadLink(link) {
    const url = new URL(link.href);
    if (url.protocol === "magnet:") return true;
    if (url.protocol !== "http:" && url.protocol !== "https:") return false;
    if (link.hasAttribute("download")) return true;
    const extension = url.pathname.split(".").pop().toLowerCase();
    return DOWNLOAD_EXTENSIONS.includes(extension);
}

document.addEventListener("click", (event) => {
    if (event.altKey) return;
    if (!settings.interceptEnabled || settings.disabledSites.includes(location.hostname)) return;

    const link = event.target.closest?.("a[href]");
    if (!link || !isDownloadLink(link)) return;

    event.preventDefault();
    location.href = harborURL(link.href);
}, true);
