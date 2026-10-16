// The background script is not persistent. Safari doesn't keep its context menu items across
// relaunches, and toggling the extension doesn't fire onInstalled, so the menu is created every
// time the script loads. removeAll first avoids a duplicate-id error.
browser.contextMenus.removeAll().then(() => {
    browser.contextMenus.create({
        id: "download-with-harbor",
        title: "Download with Harbor",
        contexts: ["link"],
    });
});

// Listening for onStartup makes Safari load this script at launch, which recreates the menu above.
browser.runtime.onStartup.addListener(() => {});

browser.contextMenus.onClicked.addListener((info, tab) => {
    browser.tabs.update(tab.id, { url: harborURL(info.linkUrl) });
});
