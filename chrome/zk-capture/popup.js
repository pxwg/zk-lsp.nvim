const statusEl = document.getElementById("status");

function send(action) {
  statusEl.textContent = "Running...";
  chrome.runtime.sendMessage({ action }, (response) => {
    const err = chrome.runtime.lastError;
    if (err) {
      statusEl.textContent = err.message;
      return;
    }
    if (response?.ok) {
      statusEl.textContent = response.status === "exists" ? "Already captured" : "Done";
    } else {
      statusEl.textContent = response?.error || "Failed";
    }
  });
}

document.getElementById("auto").addEventListener("click", () => send("captureAuto"));
document.getElementById("page").addEventListener("click", () => send("capturePage"));
document.getElementById("pdf").addEventListener("click", () => send("capturePdf"));
document.getElementById("ping").addEventListener("click", () => send("ping"));
