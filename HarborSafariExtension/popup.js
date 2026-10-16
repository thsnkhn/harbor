const interceptToggle = document.getElementById("intercept-enabled");
const siteToggle = document.getElementById("site-enabled");
const sendPageButton = document.getElementById("send-page");

async function load() {
    const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
    const settings = await browser.storage.local.get(DEFAULT_SETTINGS);
    const pageURL = tab?.url ? new URL(tab.url) : null;
    const isWebPage = pageURL?.protocol === "http:" || pageURL?.protocol === "https:";
    const site = isWebPage ? pageURL.hostname : null;

    interceptToggle.checked = settings.interceptEnabled;
    interceptToggle.addEventListener("change", () => {
        browser.storage.local.set({ interceptEnabled: interceptToggle.checked });
        siteToggle.disabled = !site || !interceptToggle.checked;
    });

    if (site) document.getElementById("site-name").textContent = site;
    siteToggle.checked = !settings.disabledSites.includes(site);
    siteToggle.disabled = !site || !settings.interceptEnabled;
    siteToggle.addEventListener("change", async () => {
        const { disabledSites } = await browser.storage.local.get(DEFAULT_SETTINGS);
        const others = disabledSites.filter((host) => host !== site);
        browser.storage.local.set({ disabledSites: siteToggle.checked ? others : [...others, site] });
    });

    sendPageButton.disabled = !isWebPage;
    sendPageButton.addEventListener("click", () => {
        browser.tabs.update(tab.id, { url: harborURL(tab.url) });
        window.close();
    });
}

load();
