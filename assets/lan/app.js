"use strict";

(() => {
  const $ = id => document.getElementById(id);
  const tasks = [], rows = new Map();
  let connected = false, enabled = false, working = false, refreshing = false;
  let chunkSize = 2 * 1024 * 1024, sharesKey = "", renderTime = 0;
  const storageKey = `wenxi-lan-pending:${location.origin}`;
  const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
  const id = () => {
    const bytes = new Uint8Array(16);
    crypto.getRandomValues(bytes);
    return Array.from(bytes, b => b.toString(16).padStart(2, "0")).join("");
  };
  let browserId;
  try { browserId = sessionStorage.getItem("wenxi-lan-id") || id(); sessionStorage.setItem("wenxi-lan-id", browserId); }
  catch (_) { browserId = id(); }
  const size = value => {
    if (value < 1024) return `${value} B`;
    const units = ["KB", "MB", "GB", "TB"];
    let n = value / 1024, i = 0;
    while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
    return `${n.toFixed(n >= 10 ? 1 : 2)} ${units[i]}`;
  };
  const fail = (message, status = 0) => Object.assign(new Error(message), { status });
  const terminal = task => task.state === "done" || task.state === "cancelled";
  const showError = (element, message) => { element.textContent = message || ""; element.hidden = !message; };
  const persist = () => {
    try {
      sessionStorage.setItem(storageKey, JSON.stringify(tasks.filter(t => !terminal(t)).slice(0, 10000)
        .map(t => ({ id: t.id, path: t.path, size: t.size, modified: t.modified, hash: t.hash }))));
    } catch (_) { /* Transfer correctness does not depend on browser storage. */ }
  };
  const stored = () => {
    try { const data = JSON.parse(sessionStorage.getItem(storageKey) || "[]"); return Array.isArray(data) ? data : []; }
    catch (_) { return []; }
  };

  async function api(path, method = "GET", body, signal) {
    const control = new AbortController();
    const abort = () => control.abort();
    if (signal?.aborted) throw fail("已取消", -1);
    signal?.addEventListener("abort", abort, { once: true });
    const timeout = setTimeout(abort, 15000);
    try {
      const response = await fetch(path, {
        method, credentials: "same-origin", cache: "no-store", signal: control.signal,
        headers: body === undefined ? {} : { "Content-Type": "application/json" },
        body: body === undefined ? undefined : JSON.stringify(body),
      });
      const data = await response.json();
      if (!response.ok) throw fail(data.error || "请求失败，请重试", response.status);
      return data;
    } catch (error) {
      if (error.status !== undefined) throw error;
      throw fail(signal?.aborted ? "已取消" : "连接中断，请确认设备互联仍然开启后重试", signal?.aborted ? -1 : 0);
    } finally {
      clearTimeout(timeout);
      signal?.removeEventListener("abort", abort);
    }
  }

  const readOffset = (data, task) => {
    if (!Number.isSafeInteger(data.offset) || data.offset < 0 || data.offset > task.size) {
      throw fail("接收进度无效，请取消后重新选择文件", 409);
    }
    task.offset = data.offset;
    return data;
  };
  const check = task => { if (task.cancelled) throw fail("已取消", -1); };

  function fileIcon(name) {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("class", "file-icon"); svg.setAttribute("aria-hidden", "true"); svg.setAttribute("focusable", "false");
    const use = document.createElementNS("http://www.w3.org/2000/svg", "use");
    use.setAttribute("href", `#icon-${name}`); svg.append(use);
    return svg;
  }

  function render(force = false) {
    if (!force && Date.now() - renderTime < 150) return;
    renderTime = Date.now();
    const pending = tasks.filter(t => !terminal(t)), completed = tasks.filter(terminal);
    const visible = [...pending, ...completed.slice(-200)].slice(0, 200);
    const visibleIds = new Set(visible.map(t => t.id));
    for (const [key, row] of rows) {
      if (!visibleIds.has(key)) { row.element.remove(); rows.delete(key); }
    }
    $("queue-count").textContent = `${tasks.length} 个文件${tasks.length > 200 ? " · 显示前 200 项" : ""}`;
    $("queue-empty").hidden = tasks.length > 0;
    $("queue-actions").hidden = pending.length === 0;
    $("retry-all").hidden = !pending.some(t => t.state === "error" && t.file);
    for (const task of visible) {
      let row = rows.get(task.id);
      if (!row) {
        const element = document.createElement("li"); element.className = "file-row";
        const icon = fileIcon("file-upload");
        const content = document.createElement("div"); content.className = "file-content";
        const name = document.createElement("p"); name.className = "file-name"; name.textContent = task.path;
        const meta = document.createElement("p"); meta.className = "file-meta"; meta.setAttribute("role", "status");
        const progress = document.createElement("progress"); progress.max = 1; progress.setAttribute("aria-label", `${task.path} 传输进度`);
        content.append(name, meta, progress);
        const controls = document.createElement("div"); controls.className = "file-controls";
        const retry = document.createElement("button"); retry.type = "button"; retry.textContent = "重试";
        retry.onclick = () => { if (task.file) { task.cancelled = false; task.state = "queued"; task.error = ""; render(true); pump(); } else { showError($("connection-error"), "请重新选择原来的文件，以继续上传。"); $("file-input").click(); } };
        const cancel = document.createElement("button"); cancel.type = "button"; cancel.className = "cancel"; cancel.textContent = "取消";
        cancel.onclick = () => cancelTask(task);
        controls.append(retry, cancel); element.append(icon, content, controls);
        row = { element, meta, progress, retry, cancel }; rows.set(task.id, row); $("upload-list").append(element);
      }
      let text = "等待发送", ratio = task.size ? task.offset / task.size : 0;
      switch (task.state) {
        case "hashing": text = `准备文件 ${Math.round((task.hashed || 0) * 100)}%`; ratio = task.hashed || 0; break;
        case "uploading": {
          const bytes = Math.min(task.size, task.offset + (task.inFlight || 0));
          ratio = task.size ? bytes / task.size : 1;
          const speed = Math.max(0, bytes - (task.startOffset || 0)) / Math.max(.1, (Date.now() - task.started) / 1000);
          text = `${size(bytes)} / ${size(task.size)}${speed > 0 ? ` · ${size(speed)}/s` : ""}`;
          break;
        }
        case "verifying": text = "已传完，设备正在校验"; ratio = 1; break;
        case "saving": text = "正在保存到设备"; ratio = 1; break;
        case "done": text = "已保存到设备"; ratio = 1; break;
        case "cancelled": text = task.error || "已取消"; break;
        case "missing": text = "重新选择原文件以继续"; break;
        case "error": text = task.error || "上传中断，请重试"; break;
      }
      row.meta.textContent = `${size(task.size)} · ${text}`;
      row.meta.classList.toggle("error", task.state === "error");
      row.progress.value = Math.min(1, Math.max(0, ratio));
      row.progress.hidden = task.state === "done" || task.state === "cancelled";
      row.retry.hidden = !["error", "missing"].includes(task.state);
      row.retry.disabled = !connected;
      row.cancel.hidden = terminal(task);
    }
  }

  async function hashFile(task) {
    task.state = "hashing"; render(true);
    const hash = new LanSha256();
    for (let offset = 0; offset < task.size; offset += 1024 * 1024) {
      check(task);
      const buffer = await task.file.slice(offset, Math.min(task.size, offset + 1024 * 1024)).arrayBuffer();
      check(task);
      hash.update(new Uint8Array(buffer));
      task.hashed = Math.min(1, (offset + buffer.byteLength) / task.size);
      render();
      await wait(0);
    }
    check(task);
    const digest = hash.digest();
    if (task.hash && task.hash !== digest) throw fail("所选文件内容已变化，请取消旧传输后重新选择", 409);
    task.hash = digest;
    task.hashedFile = task.file;
    persist();
  }

  function sendBlock(task, start, end) {
    return new Promise((resolve, reject) => {
      const xhr = new XMLHttpRequest(); task.xhr = xhr;
      const abort = () => xhr.abort();
      task.control.signal.addEventListener("abort", abort, { once: true });
      const done = () => { task.xhr = null; task.control.signal.removeEventListener("abort", abort); };
      xhr.upload.onprogress = event => { task.inFlight = event.loaded; render(); };
      xhr.onload = () => {
        done();
        let data;
        try { data = JSON.parse(xhr.responseText); } catch (_) { reject(fail("上传回应无效，请重试", 0)); return; }
        xhr.status >= 200 && xhr.status < 300 ? resolve(data) : reject(fail(data.error || "上传失败，请重试", xhr.status));
      };
      xhr.onerror = () => { done(); reject(fail("连接中断，进度已保留", 0)); };
      xhr.ontimeout = xhr.onerror;
      xhr.onabort = () => { done(); reject(fail("已取消", -1)); };
      xhr.open("PUT", `/web/uploads/${task.id}`);
      xhr.timeout = 60000;
      xhr.setRequestHeader("Content-Type", "application/octet-stream");
      xhr.setRequestHeader("Content-Range", `bytes ${start}-${end - 1}/${task.size}`);
      if (task.control.signal.aborted) { done(); reject(fail("已取消", -1)); return; }
      xhr.send(task.file.slice(start, end));
    });
  }

  async function upload(task) {
    task.control = new AbortController();
    if (task.hashedFile !== task.file) await hashFile(task);
    check(task);
    let data = readOffset(await api("/web/uploads", "POST", {
      id: task.id, path: task.path, size: task.size, sha256: task.hash,
    }, task.control.signal), task);
    if (data.state === "cancelled") throw fail("传输已取消，请重新选择文件", 410);
    task.started = Date.now(); task.startOffset = task.offset;
    while (task.offset < task.size) {
      check(task);
      task.state = "uploading"; task.inFlight = 0; render(true);
      const start = task.offset, end = Math.min(task.size, start + chunkSize);
      let accepted = false;
      for (let attempt = 0; attempt < 3; attempt++) {
        check(task);
        try { data = readOffset(await sendBlock(task, start, end), task); accepted = true; break; }
        catch (error) {
          if (![-1, 0, 408, 409, 429, 500, 502, 503, 504].includes(error.status) || error.status === -1) throw error;
          check(task);
          // Query the acknowledged prefix before replaying a lost response.
          const status = readOffset(await api(`/web/uploads/${task.id}`, "GET", undefined, task.control.signal), task);
          if (status.offset === end) { data = status; accepted = true; break; }
          if (status.offset !== start) throw fail("接收进度已变化，请取消后重新选择文件", 409);
          if (attempt === 2) throw error;
          task.inFlight = 0; render(true); await wait([500, 1500][attempt]);
        }
      }
      if (!accepted || task.offset !== end) throw fail("接收进度无效，请重试", 409);
    }
    if (data.state !== "completed") {
      task.state = "verifying"; render(true);
      try { data = await api(`/web/uploads/${task.id}/complete`, "POST", undefined, task.control.signal); }
      catch (error) {
        if (error.status !== 0) throw error;
        data = await api(`/web/uploads/${task.id}`, "GET", undefined, task.control.signal);
        if (!["completed", "saving", "verifying"].includes(data.state)) throw error;
      }
      while (data.state !== "completed") {
        check(task);
        if (data.state === "failed" || data.state === "cancelled") throw fail(data.error || "保存失败，请重试", 409);
        task.state = data.state === "saving" ? "saving" : "verifying";
        render(); await wait(650);
        data = readOffset(await api(`/web/uploads/${task.id}`, "GET", undefined, task.control.signal), task);
      }
    }
    task.state = "done"; task.offset = task.size; task.file = task.hashedFile = null;
    task.error = ""; persist(); render(true);
  }

  async function pump() {
    if (working || !connected || !enabled) return;
    working = true;
    try {
      let next;
      while (connected && (next = tasks.find(t => t.state === "queued" && t.file))) {
        try { await upload(next); }
        catch (error) {
          next.state = next.cancelled ? "cancelled" : "error";
          next.error = next.cancelled ? "已取消" : error.message;
          if (error.status === 401) loseSession(error.message);
          persist(); render(true);
        }
      }
    } finally { working = false; }
  }

  async function cancelTask(task) {
    if (terminal(task)) return;
    task.cancelled = true; task.control?.abort(); task.xhr?.abort();
    task.state = "cancelled"; task.file = task.hashedFile = null; render(true);
    try {
      const data = await api(`/web/uploads/${task.id}`, "DELETE");
      if (data.state === "completed") { task.state = "done"; task.offset = task.size; }
    } catch (error) {
      if (task.hash && error.status !== 404) task.error = "已停止发送，接收端暂存将在 30 分钟后清理";
    }
    persist(); render(true);
  }

  function addFiles(files) {
    if (!connected || !enabled) return;
    showError($("connection-error"), "");
    if (tasks.filter(t => !terminal(t)).length + files.length > 10000) {
      showError($("connection-error"), "一次最多选择 10000 个文件，请分批发送。"); return;
    }
    for (const file of files) {
      const path = file.webkitRelativePath || file.name;
      const existing = tasks.find(t => !terminal(t) && t.path === path && t.size === file.size && t.modified === file.lastModified);
      if (existing && !["missing", "error"].includes(existing.state)) continue;
      const task = existing || { id: id(), path, size: file.size, modified: file.lastModified, offset: 0 };
      task.file = file; task.state = "queued"; task.error = ""; task.cancelled = false;
      if (!existing) tasks.push(task);
    }
    persist(); render(true); pump();
  }

  function renderShares(shares) {
    const key = JSON.stringify(shares);
    if (sharesKey === key) return;
    sharesKey = key; $("share-list").replaceChildren();
    $("shares-empty").hidden = shares.length > 0;
    for (const share of shares) {
      const row = document.createElement("li"); row.className = "file-row";
      const icon = fileIcon(share.archive ? "folder" : "file");
      const content = document.createElement("div"); content.className = "file-content";
      const name = document.createElement("p"); name.className = "file-name"; name.textContent = share.name;
      const meta = document.createElement("p"); meta.className = "file-meta"; meta.textContent = `${share.fileCount} 个文件 · ${size(share.size)}`;
      content.append(name, meta);
      const controls = document.createElement("div"); controls.className = "file-controls";
      const link = document.createElement("a"), url = new URL(share.downloadUrl, location.origin);
      url.searchParams.set("transfer", id());
      link.href = url.href; link.download = ""; link.textContent = share.archive ? "下载 ZIP" : "下载";
      const details = document.createElement("a"); details.href = share.url; details.textContent = "分享页"; details.className = "secondary-link";
      details.target = "_blank"; details.rel = "noopener";
      controls.append(link, details); row.append(icon, content, controls); $("share-list").append(row);
    }
  }

  function restore(uploads) {
    const pending = stored();
    for (const upload of uploads) {
      const local = tasks.find(t => t.id === upload.id);
      if (local) {
        if (!working && upload.state === "completed") { local.state = "done"; local.offset = local.size; }
        continue;
      }
      if (["completed", "cancelled"].includes(upload.state)) continue;
      const metadata = pending.find(t => t.id === upload.id);
      tasks.push({ id: upload.id, path: metadata?.path || upload.path, size: upload.size,
        modified: metadata?.modified, hash: upload.sha256, offset: upload.offset, state: "missing" });
    }
    render(true);
  }

  function loseSession(message) {
    connected = false;
    $("pair-view").hidden = false; $("transfer-view").hidden = true;
    showError($("pair-error"), message);
  }

  async function refresh(initial = false) {
    if (refreshing) return;
    refreshing = true;
    try {
      const data = await api("/web/session");
      connected = true; enabled = data.uploadEnabled;
      chunkSize = Math.min(2 * 1024 * 1024, data.chunkSize || chunkSize);
      $("pair-view").hidden = true; $("transfer-view").hidden = false;
      $("device-name").textContent = data.name;
      $("file-input").disabled = $("folder-input").disabled = !enabled;
      if (!enabled) $("upload-help").textContent = "此版本仅支持网页下载，请更新应用后上传文件。";
      renderShares(data.shares || []); restore(data.uploads || []);
      showError($("connection-error"), ""); pump();
    } catch (error) {
      if (error.status === 401) { if (!initial) loseSession(error.message); }
      else if (!initial) showError($("connection-error"), error.message);
    } finally { refreshing = false; }
  }

  $("pair-form").onsubmit = async event => {
    event.preventDefault(); $("pair-submit").disabled = true; showError($("pair-error"), "");
    try {
      await api("/web/pair", "POST", { code: $("pair-code").value.trim(), name: $("browser-name").value.trim(), id: browserId });
      $("pair-code").value = ""; await refresh();
    } catch (error) { showError($("pair-error"), error.message); }
    finally { $("pair-submit").disabled = false; }
  };
  $("file-input").onchange = event => { addFiles(Array.from(event.target.files)); event.target.value = ""; };
  $("folder-input").onchange = event => { addFiles(Array.from(event.target.files)); event.target.value = ""; };
  $("folder-button").hidden = !("webkitdirectory" in $("folder-input"));
  $("refresh").onclick = () => refresh();
  $("retry-all").onclick = () => { for (const t of tasks) if (t.state === "error" && t.file) { t.state = "queued"; t.error = ""; } render(true); pump(); };
  $("cancel-all").onclick = async () => { for (const t of tasks.filter(t => !terminal(t))) await cancelTask(t); };
  $("disconnect").onclick = async () => {
    if (tasks.some(t => !terminal(t)) && !confirm("断开连接会取消未完成的传输，是否继续？")) return;
    $("disconnect").disabled = true;
    try {
      for (const t of tasks.filter(t => !terminal(t))) await cancelTask(t);
      await api("/web/logout", "POST"); loseSession("");
    } catch (error) { showError($("connection-error"), error.message); }
    finally { $("disconnect").disabled = false; }
  };
  const dropzone = $("dropzone");
  document.addEventListener("dragover", event => event.preventDefault());
  document.addEventListener("drop", event => event.preventDefault());
  dropzone.ondragover = event => {
    event.preventDefault();
    if (connected && enabled && Array.from(event.dataTransfer.types).includes("Files")) {
      event.dataTransfer.dropEffect = "copy";
      dropzone.classList.add("drag-over");
    }
  };
  dropzone.ondragleave = event => { if (!dropzone.contains(event.relatedTarget)) dropzone.classList.remove("drag-over"); };
  dropzone.ondrop = event => { event.preventDefault(); dropzone.classList.remove("drag-over"); addFiles(Array.from(event.dataTransfer.files)); };
  window.addEventListener("beforeunload", event => { if (working) { event.preventDefault(); event.returnValue = ""; } });
  setInterval(() => { if (connected && !document.hidden) refresh(); }, 4000);
  document.addEventListener("visibilitychange", () => { if (!document.hidden && connected) refresh(); });
  refresh(true);
})();
