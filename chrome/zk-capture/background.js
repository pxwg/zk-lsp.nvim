const HOST = "top.homeward_sky.zk_capture";

function isPdfUrl(url) {
  try {
    const parsed = new URL(url);
    return /\.pdf($|[?#])/i.test(parsed.pathname) || parsed.pathname.toLowerCase().includes("/pdf/");
  } catch (_) {
    return /\.pdf($|[?#])/i.test(url || "");
  }
}

function notify(title, message) {
  chrome.notifications.create({
    type: "basic",
    iconUrl: "icon.svg",
    title,
    message: message || "",
  });
}

function sendNative(payload) {
  return new Promise((resolve, reject) => {
    chrome.runtime.sendNativeMessage(HOST, payload, (response) => {
      const err = chrome.runtime.lastError;
      if (err) {
        reject(new Error(err.message));
        return;
      }
      resolve(response || { ok: false, error: "empty native host response" });
    });
  });
}

async function getPageData(tabId) {
  try {
    const [result] = await chrome.scripting.executeScript({
      target: { tabId },
      func: () => {
        const meta = (selector) => document.querySelector(selector)?.getAttribute("content") || "";
        const allMeta = {};
        for (const node of document.querySelectorAll("meta[name], meta[property], meta[itemprop]")) {
          const key = node.getAttribute("name") || node.getAttribute("property") || node.getAttribute("itemprop");
          const value = node.getAttribute("content") || "";
          if (!key || !value) continue;
          const normalized = key.toLowerCase();
          if (allMeta[normalized] === undefined) {
            allMeta[normalized] = value;
          } else if (Array.isArray(allMeta[normalized])) {
            allMeta[normalized].push(value);
          } else {
            allMeta[normalized] = [allMeta[normalized], value];
          }
        }
        const canonical = document.querySelector("link[rel='canonical']")?.href || "";
        const jsonLd = Array.from(document.querySelectorAll("script[type='application/ld+json']"))
          .map((node) => node.textContent || "")
          .filter(Boolean)
          .slice(0, 5);
        return {
          title: document.title || "",
          selection: window.getSelection()?.toString() || "",
          description: meta("meta[name='description']"),
          keywords: meta("meta[name='keywords']"),
          ogTitle: meta("meta[property='og:title']"),
          ogDescription: meta("meta[property='og:description']"),
          twitterTitle: meta("meta[name='twitter:title']"),
          twitterDescription: meta("meta[name='twitter:description']"),
          canonicalUrl: canonical,
          meta: allMeta,
          jsonLd,
          url: location.href,
        };
      },
    });
    return result?.result || {};
  } catch (_) {
    return {};
  }
}

function report(response, successTitle) {
  if (response?.ok) {
    if (response.status === "exists") {
      notify("Already captured", response.key ? `@${response.key}` : "Existing note found");
    } else {
      notify(successTitle, response.title || response.note_path || "Done");
    }
  } else {
    notify("ZK Capture failed", response?.error || "Unknown error");
  }
}

async function capturePage(tab) {
  const page = tab.id ? await getPageData(tab.id) : {};
  const response = await sendNative({
    action: "capturePage",
    url: tab.url || page.url,
    title: tab.title || page.title || "",
    selection: page.selection || "",
    metadata: page,
  });
  report(response, "Page captured");
  return response;
}

function downloadPdf(url, title = "") {
  const filename = `zk-capture/${crypto.randomUUID()}.pdf`;
  return new Promise((resolve, reject) => {
    chrome.downloads.download(
      {
        url,
        filename,
        conflictAction: "uniquify",
        saveAs: false,
      },
      (downloadId) => {
        const err = chrome.runtime.lastError;
        if (err) {
          reject(new Error(err.message));
          return;
        }
        const listener = (delta) => {
          if (delta.id !== downloadId || !delta.state) return;
          if (delta.state.current === "complete") {
            chrome.downloads.onChanged.removeListener(listener);
            chrome.downloads.search({ id: downloadId }, (items) => {
              const item = items?.[0];
              if (!item?.filename) {
                reject(new Error("Chrome did not return a downloaded file path"));
                return;
              }
              resolve({ path: item.filename, finalUrl: item.finalUrl || item.url || url, title });
            });
          } else if (delta.state.current === "interrupted") {
            chrome.downloads.onChanged.removeListener(listener);
            reject(new Error("PDF download was interrupted"));
          }
        };
        chrome.downloads.onChanged.addListener(listener);
      },
    );
  });
}

async function capturePdfUrl(url, title = "", tab = null) {
  const page = tab?.id ? await getPageData(tab.id) : {};
  const downloaded = await downloadPdf(url, title);
  const response = await sendNative({
    action: "capturePdfFile",
    path: downloaded.path,
    sourceUrl: downloaded.finalUrl,
    title,
    metadata: page,
  });
  report(response, "PDF captured");
  return response;
}

async function captureActivePdf(tab) {
  return capturePdfUrl(tab.url, tab.title || "", tab);
}

async function captureAuto(tab) {
  if (isPdfUrl(tab.url || "")) {
    return captureActivePdf(tab);
  }
  return capturePage(tab);
}

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({
    id: "zk-capture-page",
    title: "Capture page to ZK",
    contexts: ["page"],
  });
  chrome.contextMenus.create({
    id: "zk-capture-link-pdf",
    title: "Capture linked PDF to ZK",
    contexts: ["link"],
  });
});

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  try {
    if (info.menuItemId === "zk-capture-page" && tab) {
      await capturePage(tab);
    } else if (info.menuItemId === "zk-capture-link-pdf" && info.linkUrl) {
      await capturePdfUrl(info.linkUrl, info.selectionText || tab?.title || "", tab);
    }
  } catch (error) {
    notify("ZK Capture failed", error.message);
  }
});

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  (async () => {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    if (!tab) throw new Error("No active tab");
    if (message.action === "capturePage") return capturePage(tab);
    if (message.action === "capturePdf") return captureActivePdf(tab);
    if (message.action === "captureAuto") return captureAuto(tab);
    if (message.action === "ping") return sendNative({ action: "ping" });
    throw new Error(`Unknown action: ${message.action}`);
  })()
    .then((response) => sendResponse(response))
    .catch((error) => sendResponse({ ok: false, error: error.message }));
  return true;
});
