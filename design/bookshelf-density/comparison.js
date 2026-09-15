"use strict";

(() => {
  const data = window.UI_REVIEW_COMPARISON;
  const byId = id => document.getElementById(id);
  const make = (tag, className, value) => { const node = document.createElement(tag); if (className) node.className = className; if (value !== undefined) node.textContent = value; return node; };
  if (!data || !Array.isArray(data.scenes) || !data.scenes.length) {
    byId("scene-title").textContent = "前后对照尚未生成";
    byId("scene-focus").textContent = "请先运行 build_comparison.py，再打开输出目录中的 comparison.html。";
    byId("pair").hidden = true;
    return;
  }

  const scenes = data.scenes;
  const sceneMap = new Map(scenes.map(scene => [scene.id, scene]));
  const state = { id: sceneMap.has("native-chapters") ? "native-chapters" : scenes[0].id, resolution: "600x800", mode: "split", search: "", zoomSide: "after", native: false };
  const viewer = byId("zoom-viewer");
  let zoomOpener = null;
  const selectedScene = () => sceneMap.get(state.id);
  const selectedPair = () => selectedScene()?.pairs.find(pair => pair.locale === "zh_CN" && pair.resolution === state.resolution);
  const sideLabel = side => side === "before" ? "优化前" : "优化后";
  const dateLabel = value => value ? String(value).slice(0, 10) : "时间未记录";
  const provenanceFor = side => data[side] || {};

  function renderNavigation() {
    const list = byId("scene-list");
    const active = document.activeElement?.dataset.sceneId;
    list.replaceChildren();
    const query = state.search.trim().toLocaleLowerCase();
    let count = 0;
    for (const primary of [true, false]) {
      const matches = scenes.filter(scene => scene.primary === primary && (!query || `${scene.title} ${scene.id} ${scene.groupTitle}`.toLocaleLowerCase().includes(query)));
      if (!matches.length) continue;
      list.append(make("p", "scene-group-title", primary ? "主流程" : "状态与弹窗"));
      for (const scene of matches) {
        const button = make("button", "scene-button");
        button.type = "button";
        button.dataset.sceneId = scene.id;
        button.setAttribute("aria-current", String(scene.id === state.id));
        button.append(make("span", "", scene.title), make("small", "", scene.groupTitle));
        button.addEventListener("click", () => { state.id = scene.id; render(); list.querySelector('[aria-current="true"]')?.focus(); });
        list.append(button);
        count += 1;
      }
    }
    if (!count) list.append(make("p", "sidebar-no-results", "没有匹配的页面。"));
    if (active) [...list.querySelectorAll("button")].find(button => button.dataset.sceneId === active)?.focus();
    byId("scene-count").textContent = `${scenes.length} 个场景 · ${data.pairCount} 组同尺寸对照`;
  }

  function updateHash() {
    const params = new URLSearchParams({ scene: state.id, size: state.resolution, mode: state.mode });
    try { history.replaceState(null, "", `#${params}`); } catch (_) { /* Some local file contexts restrict history updates. */ }
  }

  function render() {
    const scene = selectedScene();
    const pair = selectedPair();
    const index = scenes.findIndex(item => item.id === scene.id);
    byId("scene-title").textContent = scene.title;
    byId("scene-id").textContent = scene.id;
    byId("scene-focus").textContent = scene.focus;
    byId("scene-position").textContent = `${index + 1} / ${scenes.length}`;
    byId("previous-scene").disabled = index === 0;
    byId("next-scene").disabled = index === scenes.length - 1;
    byId("resolution").value = state.resolution;
    for (const option of byId("resolution").options) option.disabled = !scene.pairs.some(item => item.resolution === option.value && item.locale === "zh_CN");
    document.querySelectorAll("[data-mode]").forEach(button => { if (button.tagName === "BUTTON") button.setAttribute("aria-pressed", String(button.dataset.mode === state.mode)); });
    byId("pair").dataset.mode = state.mode;
    byId("pair").hidden = !pair;
    byId("unavailable").hidden = Boolean(pair);
    byId("pair-size").textContent = pair ? `简体中文 · ${pair.width} × ${pair.height} · 两侧原始尺寸一致` : "当前尺寸未匹配";
    if (pair) {
      for (const side of ["before", "after"]) {
        const capture = pair[side];
        byId(`${side}-image`).src = capture.src;
        byId(`${side}-image`).width = pair.width;
        byId(`${side}-image`).height = pair.height;
        byId(`${side}-image`).alt = `${scene.title}，${sideLabel(side)}，${pair.width} × ${pair.height} 原生截图`;
        byId(`${side}-link`).href = capture.src;
        byId(`${side}-link`).setAttribute("aria-label", `打开${scene.title}${sideLabel(side)}原图`);
        const provenance = provenanceFor(side);
        byId(`${side}-meta`).textContent = dateLabel(provenance.capturedAt || provenance.generatedAt);
      }
    }
    renderNavigation();
    updateHash();
    if (viewer.open && pair) renderZoom();
  }

  function changeScene(offset) {
    const index = scenes.findIndex(scene => scene.id === state.id);
    const next = scenes[index + offset];
    if (next) { state.id = next.id; render(); }
  }

  function setNative(native) {
    state.native = native;
    byId("zoom-stage").classList.toggle("is-native", native);
    byId("toggle-native").textContent = native ? "适应窗口" : "原始像素";
    byId("toggle-native").setAttribute("aria-pressed", String(native));
  }

  function renderZoom() {
    const scene = selectedScene();
    const pair = selectedPair();
    if (!pair) return;
    const capture = pair[state.zoomSide];
    byId("zoom-title").textContent = `${scene.title} · ${sideLabel(state.zoomSide)}`;
    byId("zoom-image").src = capture.src;
    byId("zoom-image").alt = `${scene.title}${sideLabel(state.zoomSide)}原图`;
    byId("zoom-original").href = capture.src;
    document.querySelectorAll("[data-zoom-side]").forEach(button => button.setAttribute("aria-pressed", String(button.dataset.zoomSide === state.zoomSide)));
    setNative(false);
    byId("zoom-stage").scrollTo(0, 0);
  }

  function openZoom(side, opener) {
    if (!selectedPair()) return;
    state.zoomSide = side;
    zoomOpener = opener;
    renderZoom();
    viewer.showModal();
    document.body.style.overflow = "hidden";
    byId("close-zoom").focus();
  }

  byId("previous-scene").addEventListener("click", () => changeScene(-1));
  byId("next-scene").addEventListener("click", () => changeScene(1));
  byId("resolution").addEventListener("change", event => { state.resolution = event.target.value; render(); });
  byId("scene-search").addEventListener("input", event => { state.search = event.target.value; renderNavigation(); });
  document.querySelectorAll("button[data-mode]").forEach(button => button.addEventListener("click", () => { state.mode = button.dataset.mode; render(); }));
  document.querySelectorAll("[data-zoom]").forEach(button => button.addEventListener("click", () => openZoom(button.dataset.zoom, button)));
  document.querySelectorAll("[data-zoom-side]").forEach(button => button.addEventListener("click", () => { state.zoomSide = button.dataset.zoomSide; renderZoom(); }));
  byId("toggle-native").addEventListener("click", () => setNative(!state.native));
  byId("close-zoom").addEventListener("click", () => viewer.close());
  viewer.addEventListener("close", () => { document.body.style.overflow = ""; zoomOpener?.focus(); });
  document.addEventListener("keydown", event => {
    if (event.altKey || event.ctrlKey || event.metaKey || ["INPUT", "TEXTAREA", "SELECT"].includes(event.target.tagName)) return;
    if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
      event.preventDefault();
      if (viewer.open) { state.zoomSide = event.key === "ArrowLeft" ? "before" : "after"; renderZoom(); }
      else changeScene(event.key === "ArrowLeft" ? -1 : 1);
    }
  });

  const provenance = byId("provenance");
  for (const side of ["before", "after"]) {
    const source = provenanceFor(side);
    const parts = [`捕获日期：${dateLabel(source.capturedAt || source.generatedAt)}`];
    if (source.runtimeVersion) parts.push(`KOReader ${source.runtimeVersion}`);
    if (source.revision) parts.push(`基础提交：${String(source.revision).slice(0, 12)}`);
    provenance.append(make("dt", "", sideLabel(side)), make("dd", "", parts.join(" · ")));
  }
  byId("generated-date").textContent = `对照生成于 ${dateLabel(data.generatedAt)}`;
  byId("comparison-sheet").hidden = !data.overview;
  if (data.overview) byId("comparison-sheet").href = data.overview.src;
  const params = new URLSearchParams(location.hash.slice(1));
  if (sceneMap.has(params.get("scene"))) state.id = params.get("scene");
  if (["600x800", "480x640"].includes(params.get("size"))) state.resolution = params.get("size");
  if (["split", "before", "after"].includes(params.get("mode"))) state.mode = params.get("mode");
  if (!selectedPair()) state.resolution = selectedScene().pairs[0].resolution;
  render();
})();
