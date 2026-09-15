"use strict";

(() => {
  const locale = window.RECHARGE_PREVIEW_LOCALE;
  const manifest = window.RECHARGE_PREVIEW_MANIFEST || { scenes: [] };
  const byId = id => document.getElementById(id);
  if (!locale || !locale.ui || !Array.isArray(locale.scenes)) {
    document.title = "Recharge preview data unavailable";
    byId("scene-title").textContent = "Locale data unavailable: zh-CN.js";
    return;
  }
  const ui = locale.ui;
  const format = (value, fields = {}) => String(value || "").replace(/\{(\w+)\}/g, (match, key) => fields[key] ?? match);
  document.title = `BiliComics · ${ui.title}`;
  document.querySelectorAll("[data-copy]").forEach(node => { node.textContent = ui[node.dataset.copy] || ""; });
  document.querySelectorAll("[data-aria]").forEach(node => node.setAttribute("aria-label", ui[node.dataset.aria] || ""));
  document.querySelectorAll("[data-placeholder]").forEach(node => { node.placeholder = ui[node.dataset.placeholder] || ""; });

  const validId = id => typeof id === "string" && /^[a-z0-9][a-z0-9_-]*$/.test(id);
  const sceneMap = new Map();
  for (const scene of locale.scenes) if (validId(scene.id)) sceneMap.set(scene.id, { ...scene });
  for (const record of Array.isArray(manifest.scenes) ? manifest.scenes : []) {
    const item = typeof record === "string" ? { id: record } : record;
    if (!item || !validId(item.id)) continue;
    const translated = sceneMap.get(item.id);
    sceneMap.set(item.id, translated ? { ...translated, sizes: item.sizes } : {
      id: item.id, title: ui.fallbackTitle, note: ui.fallbackNote, main: false, sizes: item.sizes,
    });
  }
  const scenes = [...sceneMap.values()];
  if (!scenes.length) { byId("scene-title").textContent = ui.unavailableData; return; }
  const state = { id: scenes[0].id, size: "600x800", query: "", loadId: 0, loaded: false, native: false };
  const viewer = byId("viewer");
  let zoomRequest = 0;
  const make = (tag, className, value) => { const node = document.createElement(tag); if (className) node.className = className; if (value !== undefined) node.textContent = value; return node; };
  const scene = () => sceneMap.get(state.id);
  const source = item => `screens/${state.size}/${encodeURIComponent(item.id)}.png`;
  const expectedSize = () => state.size.split("x").map(Number);
  const displaySize = () => state.size.replace("x", " × ");
  const matches = () => { const query = state.query.trim().toLocaleLowerCase(); return scenes.filter(item => !query || `${item.title} ${item.note} ${item.id}`.toLocaleLowerCase().includes(query)); };

  function setAvailable(available) {
    state.loaded = available;
    byId("open-zoom").disabled = !available;
    byId("original").classList.toggle("is-disabled", !available);
    byId("original").setAttribute("aria-disabled", String(!available));
    byId("original").tabIndex = available ? 0 : -1;
    if (available) byId("original").href = source(scene());
    else byId("original").removeAttribute("href");
  }

  function renderNavigation() {
    const nav = byId("scene-nav");
    const focused = document.activeElement?.dataset.sceneId;
    nav.replaceChildren();
    const visible = matches();
    for (const main of [true, false]) {
      const group = visible.filter(item => Boolean(item.main) === main);
      if (!group.length) continue;
      nav.append(make("p", "scene-group-title", main ? ui.mainFlow : ui.allStates));
      for (const item of group) {
        const button = make("button", "scene-button");
        button.type = "button";
        button.dataset.sceneId = item.id;
        button.setAttribute("aria-current", String(item.id === state.id));
        button.setAttribute("aria-label", `${item.title} · ${item.id}`);
        const frame = make("span", "thumb-frame");
        const thumb = make("img");
        thumb.alt = "";
        thumb.setAttribute("aria-hidden", "true");
        thumb.loading = "lazy";
        thumb.decoding = "async";
        thumb.width = 90;
        thumb.height = 120;
        thumb.addEventListener("error", () => { thumb.hidden = true; if (!frame.querySelector(".thumb-error")) frame.append(make("span", "thumb-error", ui.missingTitle)); });
        thumb.src = source(item);
        frame.append(thumb);
        const label = make("span", "thumb-label");
        label.append(make("span", "thumb-index", String(scenes.indexOf(item) + 1).padStart(2, "0")), make("span", "", item.title));
        button.append(frame, label);
        button.addEventListener("click", () => { state.id = item.id; render(); nav.querySelector('[aria-current="true"]')?.focus(); });
        nav.append(button);
      }
    }
    if (!visible.length) nav.append(make("p", "no-matches", ui.noMatches));
    if (focused) [...nav.querySelectorAll("button")].find(button => button.dataset.sceneId === focused)?.focus();
    byId("scene-count").textContent = format(ui.scenesCount, { count: scenes.length });
  }

  function failImage(request, path) {
    if (request !== state.loadId) return;
    byId("loading").hidden = true;
    byId("image-link").hidden = true;
    byId("missing").hidden = false;
    byId("missing-message").textContent = ui.missingBody;
    byId("missing-path").textContent = path;
    setAvailable(false);
  }

  function loadImage() {
    const request = ++state.loadId;
    const path = source(scene());
    const dimensions = expectedSize();
    const image = make("img");
    image.id = "main-image";
    image.decoding = "async";
    setAvailable(false);
    byId("image-link").hidden = true;
    byId("missing").hidden = true;
    byId("loading").hidden = false;
    image.alt = format(ui.imageAlt, { title: scene().title, size: displaySize() });
    image.onload = () => {
      if (request !== state.loadId) return;
      if (image.naturalWidth !== dimensions[0] || image.naturalHeight !== dimensions[1]) { failImage(request, path); return; }
      byId("main-image").replaceWith(image);
      byId("loading").hidden = true;
      byId("missing").hidden = true;
      byId("image-link").hidden = false;
      byId("image-link").href = path;
      byId("image-link").setAttribute("aria-label", `${ui.openOriginal} · ${scene().title}`);
      setAvailable(true);
    };
    image.onerror = () => failImage(request, path);
    image.src = path;
  }

  function updateStep() {
    const visible = matches();
    const index = visible.findIndex(item => item.id === state.id);
    byId("previous").disabled = !visible.length || index <= 0;
    byId("next").disabled = !visible.length || index >= visible.length - 1;
    byId("scene-position").textContent = `${scenes.findIndex(item => item.id === state.id) + 1} / ${scenes.length}`;
  }

  function render() {
    byId("scene-title").textContent = scene().title;
    byId("scene-id").textContent = scene().id;
    byId("scene-note").textContent = scene().note;
    byId("image-size").textContent = displaySize();
    byId("resolution").value = state.size;
    renderNavigation();
    updateStep();
    loadImage();
    try { history.replaceState(null, "", `#${new URLSearchParams({ scene: state.id, size: state.size })}`); } catch (_) { /* Local file history may be restricted. */ }
  }

  function changeScene(delta) {
    const visible = matches();
    const index = visible.findIndex(item => item.id === state.id);
    const next = visible[index + delta];
    if (next) { state.id = next.id; render(); }
  }

  function setNative(native) {
    state.native = native;
    byId("viewer-stage").classList.toggle("is-native", native);
    byId("native-toggle").textContent = native ? ui.fit : ui.nativePixels;
    byId("native-toggle").setAttribute("aria-pressed", String(native));
  }

  function openViewer() {
    if (!state.loaded) return;
    const request = ++zoomRequest;
    const zoomImage = make("img");
    zoomImage.id = "viewer-image";
    const dimensions = expectedSize();
    byId("viewer-title").textContent = `${scene().title} · ${displaySize()}`;
    byId("viewer-loading").hidden = false;
    byId("viewer-error").hidden = true;
    byId("viewer-image").hidden = true;
    zoomImage.hidden = true;
    zoomImage.alt = format(ui.imageAlt, { title: scene().title, size: displaySize() });
    zoomImage.onload = () => {
      if (request !== zoomRequest) return;
      byId("viewer-loading").hidden = true;
      const valid = zoomImage.naturalWidth === dimensions[0] && zoomImage.naturalHeight === dimensions[1];
      zoomImage.hidden = !valid;
      byId("viewer-error").hidden = valid;
      if (valid) byId("viewer-image").replaceWith(zoomImage);
    };
    zoomImage.onerror = () => { if (request === zoomRequest) { byId("viewer-loading").hidden = true; zoomImage.hidden = true; byId("viewer-error").hidden = false; } };
    zoomImage.src = source(scene());
    setNative(false);
    byId("viewer-stage").scrollTo(0, 0);
    viewer.showModal();
    document.body.style.overflow = "hidden";
    byId("close-viewer").focus();
  }

  byId("scene-search").addEventListener("input", event => { state.query = event.target.value; renderNavigation(); updateStep(); });
  byId("resolution").addEventListener("change", event => { state.size = event.target.value; render(); });
  byId("previous").addEventListener("click", () => changeScene(-1));
  byId("next").addEventListener("click", () => changeScene(1));
  byId("open-zoom").addEventListener("click", openViewer);
  byId("native-toggle").addEventListener("click", () => setNative(!state.native));
  byId("close-viewer").addEventListener("click", () => viewer.close());
  viewer.addEventListener("close", () => { zoomRequest += 1; document.body.style.overflow = ""; byId("open-zoom").focus(); });
  document.addEventListener("keydown", event => {
    if (viewer.open || event.altKey || event.ctrlKey || event.metaKey || ["INPUT", "TEXTAREA", "SELECT"].includes(event.target.tagName)) return;
    if (event.key === "ArrowLeft" || event.key === "ArrowRight") { event.preventDefault(); changeScene(event.key === "ArrowLeft" ? -1 : 1); }
  });
  const params = new URLSearchParams(location.hash.slice(1));
  if (sceneMap.has(params.get("scene"))) state.id = params.get("scene");
  if (["600x800", "480x640"].includes(params.get("size"))) state.size = params.get("size");
  render();
})();
