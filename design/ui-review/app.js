"use strict";

(() => {
  const copy = {
    skip: "跳到截图", export: "导出审阅记录", navigation: "按页面浏览", language: "界面语言", resolution: "屏幕尺寸",
    marks: "审阅标记", improve: "待改进", pass: "通过", discuss: "待讨论", unreviewed: "未审阅",
    storageNote: "标记和笔记保存在当前浏览器。讨论前可导出 JSON，保留具体截图的编号、尺寸和意见。",
    eyebrow: "原生界面 · 逐页审阅", overviewImage: "打开主流程总览图 ↗", overview: "主流程概览", all: "全部截图", states: "状态与弹窗",
    intro: "以下图片来自当前插件在 KOReader 中的实际渲染，使用合成账户、漫画和交易数据；中文界面中的英文书名也是测试内容。截图反映现有实现，可用于检查布局、文案、操作顺序和异常反馈。",
    viewFilter: "截图类型", search: "搜索页面", searchPlaceholder: "搜索标题、编号或笔记…", reviewFilter: "按审阅标记筛选", allMarks: "所有标记",
    openHint: "点开截图，可查看原始像素并记录意见", emptyTitle: "没有匹配的截图", emptyBody: "试试其他语言、尺寸或关键词；不同场景的捕获范围可能不同。",
    clearFilters: "清除筛选", footer: "原图保持捕获时的内容与尺寸。合成数据用于展示 UI 状态，不代表真实服务结果。",
    previous: "上一张截图", next: "下一张截图", close: "关闭 · Esc", zoom: "切换适应窗口和原始像素", original: "打开原图 ↗", nativePixels: "原始像素", fitImage: "适应窗口",
    sourceNote: "真实 KOReader 控件 · 合成测试数据。此处的批注仅记录审阅意见，不会修改插件。",
    reviewMark: "这张截图的审阅结论", notes: "审阅笔记", notesPlaceholder: "记录位置、问题和预期行为，例如：底部操作过密，建议合并次要入口。",
    keyboardHint: "← / → 切换截图 · Esc 关闭。点击图片可切换到原始像素。", saved: "审阅记录已保存在此浏览器", sessionOnly: "浏览器存储不可用；请导出记录以保存", noteSaved: "已保存这张截图的意见", noData: "尚未生成截图数据。请运行 build_gallery.py 后打开输出目录中的 index.html。",
  };
  document.querySelectorAll("[data-copy]").forEach(node => { node.textContent = copy[node.dataset.copy] || node.dataset.copy; });
  document.querySelectorAll("[data-aria]").forEach(node => { node.setAttribute("aria-label", copy[node.dataset.aria]); });
  document.querySelectorAll("[data-placeholder]").forEach(node => { node.placeholder = copy[node.dataset.placeholder]; });

  const data = window.UI_REVIEW_DATA;
  const byId = id => document.getElementById(id);
  if (!data || !Array.isArray(data.screens)) {
    byId("page-title").textContent = "截图图集尚未生成";
    byId("capture-info").textContent = copy.noData;
    byId("export").disabled = true;
    return;
  }

  const storageKey = "bilicomics-ui-review-v1";
  const state = { group: "all", view: "overview", language: "zh_CN", resolution: "600x800", query: "", review: "all", visible: [], currentId: null, opener: null, nativePixels: false };
  let reviews = {};
  let storageAvailable = true;
  try {
    const stored = JSON.parse(localStorage.getItem(storageKey) || "{}");
    if (stored && typeof stored === "object" && !Array.isArray(stored)) reviews = stored;
  } catch (_) { storageAvailable = false; }

  const groups = data.groups || [];
  const groupMap = new Map(groups.map(group => [group.id, group]));
  const screenMap = new Map(data.screens.map(screen => [screen.id, screen]));
  const allowedStatuses = ["unreviewed", "improve", "pass", "discuss"];
  const gallery = byId("gallery");
  const viewer = byId("viewer");
  const make = (tag, className, value) => { const node = document.createElement(tag); if (className) node.className = className; if (value !== undefined) node.textContent = value; return node; };
  const variantFor = screen => screen.variants.find(variant => variant.locale === state.language && variant.resolution === state.resolution);
  const reviewKey = (screen, variant) => `${screen.id}__${variant.locale}-${variant.resolution}`;
  const reviewFor = (screen, variant) => { const item = reviews[reviewKey(screen, variant)] || {}; return { status: allowedStatuses.includes(item.status) ? item.status : "unreviewed", note: typeof item.note === "string" ? item.note : "" }; };
  const localeLabel = locale => locale === "zh_CN" ? "简体中文" : "English";
  const selectedRecord = () => { const screen = screenMap.get(state.currentId); return screen ? { screen, variant: variantFor(screen) } : null; };
  const getAvailableScreens = () => data.screens.filter(screen => variantFor(screen));

  const availableLocales = new Set(data.screens.flatMap(screen => screen.variants.map(variant => variant.locale)));
  if (!availableLocales.has(state.language)) state.language = availableLocales.has("en") ? "en" : [...availableLocales][0];
  for (const option of byId("language").options) option.disabled = !availableLocales.has(option.value);
  const availableResolutions = [...new Set(data.screens.flatMap(screen => screen.variants.map(variant => variant.resolution)))];
  for (const resolution of availableResolutions) {
    if (![...byId("resolution").options].some(option => option.value === resolution)) byId("resolution").add(new Option(resolution.replace("x", " × "), resolution));
  }
  for (const option of byId("resolution").options) option.disabled = !availableResolutions.includes(option.value);
  if (!availableResolutions.includes(state.resolution)) state.resolution = availableResolutions[0];

  function updateSaveStatus() {
    byId("save-status").textContent = storageAvailable ? copy.saved : copy.sessionOnly;
    const counts = { improve: 0, pass: 0, discuss: 0 };
    for (const screen of data.screens) for (const variant of screen.variants) { const status = reviewFor(screen, variant).status; if (status in counts) counts[status] += 1; }
    for (const [status, count] of Object.entries(counts)) byId(`count-${status}`).textContent = String(count);
  }

  function renderGroups() {
    const container = byId("groups");
    container.replaceChildren();
    const currentScreens = getAvailableScreens();
    [{ id: "all", title: "所有页面", symbol: "▦" }, ...groups].forEach(group => {
      const button = make("button", "group-button");
      button.type = "button";
      button.dataset.group = group.id;
      button.setAttribute("aria-pressed", String(group.id === state.group));
      const symbol = make("span", "group-symbol", group.symbol || "□");
      symbol.setAttribute("aria-hidden", "true");
      button.append(symbol, make("span", "", group.title), make("span", "group-count", String(currentScreens.filter(screen => group.id === "all" || screen.group === group.id).length)));
      button.addEventListener("click", () => { state.group = group.id; if (group.id !== "all") state.view = "all"; render(); byId("groups").querySelector('[aria-pressed="true"]')?.focus(); });
      container.append(button);
    });
  }

  function renderCard(screen, index) {
    const variant = variantFor(screen);
    const review = reviewFor(screen, variant);
    const article = make("article", "screen-card");
    const button = make("button", "screen-button");
    button.type = "button";
    button.dataset.screenId = screen.id;
    button.setAttribute("aria-label", `${screen.title}，${localeLabel(variant.locale)}，${variant.width} × ${variant.height}，${copy[review.status]}，打开审阅`);
    const frame = make("span", "screen-frame");
    const img = make("img");
    img.src = variant.src;
    img.alt = screen.title;
    img.loading = index < 6 ? "eager" : "lazy";
    img.decoding = "async";
    img.width = variant.width;
    img.height = variant.height;
    frame.append(make("span", "screen-number", String(screen.number).padStart(3, "0")), img);
    const caption = make("span", "card-caption");
    const topline = make("span", "card-topline");
    topline.append(make("span", "card-title", screen.title));
    if (review.status !== "unreviewed") {
      const badge = make("span", `card-status ${review.status}`);
      badge.append(make("i", `status-dot ${review.status}`), make("span", "", copy[review.status]));
      topline.append(badge);
    }
    caption.append(topline, make("span", "card-group", `${groupMap.get(screen.group)?.title || "其他页面"} · ${screen.kind === "main" ? "主页面" : "状态 / 弹窗"} · ${variant.width} × ${variant.height}`), make("span", "card-id", screen.id));
    button.append(frame, caption);
    button.addEventListener("click", () => openViewer(screen.id, button));
    article.append(button);
    if (review.note) article.append(make("p", "card-note", review.note));
    return article;
  }

  function render() {
    byId("language").value = state.language;
    byId("resolution").value = state.resolution;
    byId("search").value = state.query;
    byId("review-filter").value = state.review;
    document.querySelectorAll("[data-view]").forEach(button => button.setAttribute("aria-pressed", String(button.dataset.view === state.view)));
    byId("page-title").textContent = state.group === "all" ? (state.view === "overview" ? "从主流程开始" : state.view === "state" ? "检查状态与反馈" : "逐页审阅") : groupMap.get(state.group)?.title || "逐页审阅";
    renderGroups();
    const query = state.query.trim().toLocaleLowerCase();
    state.visible = getAvailableScreens().filter(screen => {
      if (state.group !== "all" && screen.group !== state.group) return false;
      if (state.view === "overview" && !(data.overviewIds || []).includes(screen.id)) return false;
      if (state.view === "state" && screen.kind !== "state") return false;
      const review = reviewFor(screen, variantFor(screen));
      if (state.review !== "all" && review.status !== state.review) return false;
      return !query || `${screen.title} ${screen.id} ${screen.filename} ${screen.suite} ${groupMap.get(screen.group)?.title || ""} ${review.note}`.toLocaleLowerCase().includes(query);
    });
    gallery.replaceChildren(...state.visible.map(renderCard));
    byId("empty").hidden = state.visible.length > 0;
    byId("results-count").textContent = `${state.visible.length} 个场景 · ${localeLabel(state.language)} · ${state.resolution.replace("x", " × ")}`;
    updateSaveStatus();
  }

  function setZoom(nativePixels) {
    state.nativePixels = nativePixels;
    document.querySelector(".viewer-image-area").classList.toggle("is-native", nativePixels);
    byId("zoom-button").textContent = nativePixels ? copy.fitImage : copy.nativePixels;
    byId("image-zoom").setAttribute("aria-pressed", String(nativePixels));
  }

  function renderViewer() {
    const record = selectedRecord();
    if (!record?.variant) return;
    const { screen, variant } = record;
    const review = reviewFor(screen, variant);
    const index = state.visible.findIndex(item => item.id === screen.id);
    byId("viewer-position").textContent = `${index + 1} / ${state.visible.length}`;
    byId("previous").disabled = index <= 0;
    byId("next").disabled = index < 0 || index >= state.visible.length - 1;
    byId("viewer-group").textContent = `${String(screen.number).padStart(3, "0")} / ${groupMap.get(screen.group)?.title || "页面"}`;
    byId("viewer-title").textContent = screen.title;
    byId("viewer-id").textContent = screen.id;
    byId("viewer-meta").textContent = `${localeLabel(variant.locale)} · ${variant.width} × ${variant.height} · ${screen.suite}`;
    byId("viewer-image").src = variant.src;
    byId("viewer-image").alt = `${screen.title}，${variant.width} × ${variant.height} 原生截图`;
    byId("original-link").href = variant.src;
    document.querySelectorAll("input[name=review-status]").forEach(input => { input.checked = input.value === review.status; });
    byId("review-note").value = review.note;
    byId("note-feedback").textContent = review.note || review.status !== "unreviewed" ? (storageAvailable ? copy.noteSaved : copy.sessionOnly) : "";
    setZoom(false);
    document.querySelector(".viewer-image-area").scrollTo(0, 0);
    const params = new URLSearchParams({ screen: screen.id, language: state.language, resolution: state.resolution });
    try { history.replaceState(null, "", `#${params}`); } catch (_) { /* Local file history may be restricted. */ }
  }

  function openViewer(id, opener) {
    state.currentId = id;
    state.opener = opener;
    renderViewer();
    if (!viewer.open) viewer.showModal();
    document.body.style.overflow = "hidden";
    byId("close-viewer").focus();
  }

  function closeViewer() { viewer.close(); }

  function moveViewer(offset) {
    const index = state.visible.findIndex(item => item.id === state.currentId);
    const target = state.visible[index + offset];
    if (target) { state.currentId = target.id; renderViewer(); }
  }

  function saveReview() {
    const record = selectedRecord();
    if (!record?.variant) return;
    const { screen, variant } = record;
    const status = document.querySelector("input[name=review-status]:checked")?.value || "unreviewed";
    const note = byId("review-note").value;
    const key = reviewKey(screen, variant);
    if (status === "unreviewed" && !note.trim()) delete reviews[key];
    else reviews[key] = { screenId: screen.id, title: screen.title, locale: variant.locale, resolution: variant.resolution, source: variant.src, status, note, updatedAt: new Date().toISOString() };
    try { localStorage.setItem(storageKey, JSON.stringify(reviews)); storageAvailable = true; } catch (_) { storageAvailable = false; }
    byId("note-feedback").textContent = storageAvailable ? copy.noteSaved : copy.sessionOnly;
    updateSaveStatus();
  }

  byId("language").addEventListener("change", event => { state.language = event.target.value; render(); });
  byId("resolution").addEventListener("change", event => { state.resolution = event.target.value; render(); });
  byId("search").addEventListener("input", event => { state.query = event.target.value; render(); });
  byId("review-filter").addEventListener("change", event => { state.review = event.target.value; render(); });
  document.querySelectorAll("[data-view]").forEach(button => button.addEventListener("click", () => { state.view = button.dataset.view; if (state.view === "overview") state.group = "all"; render(); }));
  byId("clear-filters").addEventListener("click", () => { state.group = "all"; state.view = "all"; state.query = ""; state.review = "all"; render(); });
  byId("previous").addEventListener("click", () => moveViewer(-1));
  byId("next").addEventListener("click", () => moveViewer(1));
  byId("close-viewer").addEventListener("click", closeViewer);
  byId("image-zoom").addEventListener("click", () => setZoom(!state.nativePixels));
  byId("zoom-button").addEventListener("click", () => setZoom(!state.nativePixels));
  byId("review-note").addEventListener("input", saveReview);
  document.querySelectorAll("input[name=review-status]").forEach(input => input.addEventListener("change", saveReview));
  viewer.addEventListener("close", () => {
    const id = state.currentId;
    document.body.style.overflow = "";
    render();
    const button = [...gallery.querySelectorAll("button[data-screen-id]")].find(item => item.dataset.screenId === id);
    (button || byId("gallery")).focus();
    try { history.replaceState(null, "", `${location.pathname}${location.search}`); } catch (_) { /* Local file history may be restricted. */ }
  });
  viewer.addEventListener("click", event => { if (event.target !== viewer) return; const rect = viewer.getBoundingClientRect(); if (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom) closeViewer(); });
  viewer.addEventListener("keydown", event => {
    if (["TEXTAREA", "INPUT", "SELECT"].includes(event.target.tagName)) return;
    if (event.key === "ArrowLeft" || event.key === "ArrowRight") { event.preventDefault(); moveViewer(event.key === "ArrowLeft" ? -1 : 1); }
  });
  byId("export").addEventListener("click", () => {
    const payload = { schemaVersion: 1, exportedAt: new Date().toISOString(), captureGeneratedAt: data.generatedAt, project: "bilicomics.koplugin", reviews: Object.values(reviews) };
    const url = URL.createObjectURL(new Blob([JSON.stringify(payload, null, 2)], { type: "application/json;charset=utf-8" }));
    const link = make("a");
    link.href = url;
    link.download = `bilicomics-ui-review-${new Date().toISOString().slice(0, 10)}.json`;
    document.body.append(link);
    link.click();
    link.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  });

  const info = byId("capture-info");
  info.append(make("span", "", `${data.screens.length} 个独立场景 / ${data.captureCount} 张原图`));
  info.append(make("span", "", `${availableResolutions.length} 种屏幕尺寸 / ${availableLocales.size} 种界面语言`));
  if (data.provenance?.revision) info.append(make("span", "utility", `版本 ${String(data.provenance.revision).slice(0, 12)}`));
  byId("manifest-version").textContent = `生成于 ${String(data.generatedAt || "").slice(0, 10)}`;

  const deepLink = new URLSearchParams(location.hash.slice(1));
  const linkedScreen = screenMap.get(deepLink.get("screen"));
  if (linkedScreen) {
    const requested = linkedScreen.variants.find(variant => variant.locale === deepLink.get("language") && variant.resolution === deepLink.get("resolution"));
    const variant = requested || linkedScreen.variants[0];
    state.language = variant.locale;
    state.resolution = variant.resolution;
    state.view = "all";
    render();
    openViewer(linkedScreen.id, null);
  } else render();
})();
