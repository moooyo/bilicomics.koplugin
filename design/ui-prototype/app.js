const copy = await fetch(new URL("locales/zh-CN.json", import.meta.url)).then(response => response.json());
const root = document.getElementById("prototype");
const params = new URLSearchParams(location.search);
const embed = params.get("embed") === "1";
const asset = name => new URL(`assets/${name}.svg`, import.meta.url).href;
const escape = value => String(value ?? "").replace(/[&<>"']/g, char => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[char]));
function t(key, values = {}) {
  let text = key.split(".").reduce((value, part) => value?.[part], copy) ?? key;
  if (typeof text !== "string") return text;
  for (const [name, value] of Object.entries(values)) text = text.replaceAll(`{${name}}`, value);
  return text;
}
const paths = {
  book: '<path d="M4 4h6c2 0 2 1 2 2v15c0-2-2-3-4-3H4zM20 4h-6c-2 0-2 1-2 2v15c0-2 2-3 4-3h4z"/>',
  bookmark: '<path d="M6 3h12v19l-6-4-6 4z"/>',
  search: '<circle cx="10.5" cy="10.5" r="6.5"/><path d="m15.5 15.5 5 5"/>',
  download: '<path d="M12 3v12m-5-5 5 5 5-5M4 16v5h16v-5"/>',
  grid: '<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/>',
  chevron: '<path d="m9 5 7 7-7 7"/>',
  back: '<path d="m14 5-7 7 7 7"/>',
  close: '<path d="m6 6 12 12M6 18 18 6"/>',
  more: '<circle cx="5" cy="12" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/>',
  wifi: '<path d="M3 8c5-4 13-4 18 0M6 12c3-3 9-3 12 0m-9 4c2-2 4-2 6 0"/><circle cx="12" cy="20" r=".8"/>',
  offline: '<path d="M3 3 21 21M8 6c5-1 9 0 13 2M3 8l2-1m1 5 2-1m5 0c2 0 4 0 5 1m-9 4c2-2 4-2 6 0"/><circle cx="12" cy="20" r=".8"/>',
  check: '<path d="m5 12 4 4L20 5"/>',
  lock: '<rect x="5" y="10" width="14" height="11" rx="2"/><path d="M8 10V7a4 4 0 0 1 8 0v3m-4 5v2"/>',
  refresh: '<path d="M20 8a8 8 0 1 0 0 8M20 3v5h-5"/>',
  user: '<circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 6v6l4 3"/>',
  settings: '<path d="M4 7h16M4 17h16"/><circle cx="9" cy="7" r="3" fill="white"/><circle cx="16" cy="17" r="3" fill="white"/>',
  list: '<path d="M8 5h13M8 12h13M8 19h13M3 5h1M3 12h1M3 19h1"/>',
  wallet: '<path d="M20 6H5a2 2 0 0 1 0-4h13v4M3 4v15c0 1 1 2 2 2h15V6m0 5h-6v5h6"/>',
  alert: '<circle cx="12" cy="12" r="9"/><path d="M12 6v7m0 4v1"/>',
  arrow: '<path d="M3 12h17m-6-6 6 6-6 6"/>',
  plus: '<path d="M12 4v16M4 12h16"/>',
};
const icon = (name, className = "") => `<svg class="icon ${className}" viewBox="0 0 24 24" aria-hidden="true">${paths[name] || paths.book}</svg>`;
const books = [
  { id: "shanhai", latest: 32, chapter: 12, page: 8, total: 24, ownedThrough: 12, updated: true, finished: false },
  { id: "deepsea", latest: 18, chapter: 6, page: 14, total: 26, ownedThrough: 12, updated: true, finished: false },
  { id: "friday", latest: 24, chapter: 22, page: 3, total: 18, ownedThrough: 24, updated: false, finished: true },
  { id: "snowline", latest: 11, chapter: 8, page: 6, total: 20, ownedThrough: 11, updated: false, finished: true },
];
function initialState() {
  return {
    view: "continue", book: "shanhai", offline: false, large: false, filter: "all", followingPage: 0,
    catalogFilter: "all", catalogPage: 2, descending: false, selecting: false, selected: new Set(),
    query: "", searched: false, modal: null, purchaseMode: "single", batchCount: 5,
    method: "coins", scenario: "normal", purchasePhase: "quote", purchaseEpisode: 13,
    balance: 180, coupons: 2, purchased: new Set(), followed: new Set(books.map(book => book.id)), transaction: null,
    readerChapter: 12, readerPage: 8, readerMenu: false, readerEnd: false,
    prefetch: true, toast: "", manageDownloads: false, downloadListOnly: false, showAllJobs: false,
    jobs: [
      { id: "job-1", book: "shanhai", start: 9, end: 11, done: 32, total: 60, status: "running" },
      { id: "job-2", book: "deepsea", start: 6, end: 6, done: 18, total: 24, status: "paused" },
    ],
    completed: [
      { id: "saved-1", book: "shanhai", start: 12, end: 12, size: 23 },
      { id: "saved-2", book: "friday", start: 20, end: 24, size: 64 },
      { id: "saved-3", book: "snowline", start: 6, end: 11, size: 169 },
    ],
  };
}
let state = initialState();
let toastTimer;
let purchaseTimer;
let lastModal = null;
const accessKey = (book, number) => `${book}:${number}`;
const currentBook = () => books.find(book => book.id === state.book) || books[0];
const title = id => t(`book.${id}.title`);
const episodeTitle = number => t("episodeTitles")[number] || t(`book.${state.book}.chapter`);
const episodeName = number => `${t("chapterNumber", { number })}  ${episodeTitle(number)}`;
const activeRoute = () => state.modal === "purchase" ? "purchase" : state.view;
function cover(id, { flag = "", className = "" } = {}) {
  return `<span class="cover ${className}"><img src="${asset(id)}" alt="" draggable="false"><span class="cover-title">${escape(title(id))}</span>${flag ? `<span class="cover-flag">${escape(flag)}</span>` : ""}</span>`;
}
function button(text, action, { primary = false, className = "", data = "", disabled = false, symbol = "" } = {}) {
  return `<button type="button" class="bc-button ${primary ? "primary" : ""} ${className}" data-action="${action}" ${data} ${disabled ? "disabled" : ""}>${symbol ? icon(symbol) : ""}${escape(text)}</button>`;
}
function header(label, { detail = false, back = false, trailing = "settings" } = {}) {
  return `<header class="bc-header ${detail ? "is-detail" : ""}"><div class="header-leading">${back ? `<button class="icon-button" data-action="back" aria-label="${t("back")}">${icon("back")}</button>` : ""}<h1>${escape(label)}</h1></div><button class="icon-button" data-route="${trailing}" aria-label="${t("more")}">${icon("more")}</button></header>`;
}
function statusBar() {
  return `<div class="bc-status"><span>09:41</span><span class="status-symbols">${state.offline ? `<span>${t("offline")}</span>` : ""}${icon(state.offline ? "offline" : "wifi")}<span>78%</span><span class="battery" aria-hidden="true"></span></span></div>`;
}
function navigation() {
  return `<nav class="bc-bottom" aria-label="${t("labNavigation")}">${[["continue", "book"], ["following", "bookmark"], ["search", "search"], ["downloads", "download"]].map(([view, symbol]) => `<button data-route="${view}" class="${state.view === view ? "is-active" : ""}" ${state.view === view ? 'aria-current="page"' : ""}>${icon(symbol)}<span>${t(view)}</span></button>`).join("")}</nav>`;
}
function progress(percent, className = "") {
  return `<div class="progress-track ${className}" aria-hidden="true"><span style="width:${Math.max(0, Math.min(100, percent))}%"></span></div>`;
}
function pagination(page, total, action) {
  return `<div class="pagination"><button data-action="${action}" data-direction="-1" ${page === 0 ? "disabled" : ""}>${t("firstPage")}</button><span>${t("pageNumber", { page: page + 1, total: Math.max(1, total) })}</span><button data-action="${action}" data-direction="1" ${page >= total - 1 ? "disabled" : ""}>${t("nextPage")}</button></div>`;
}
function offlineBanner(label) {
  return state.offline ? `<div class="offline-banner">${icon("offline")}<span>${escape(label)}</span></div>` : "";
}
function continueScreen() {
  const book = books[0];
  return `${header(t("continueTitle"))}<main class="bc-content continue-content">
    <div class="top-context"><span class="small-note">${t("localProgress")}</span><button class="text-button" data-action="show-updates">${t("updatedWorks")}${icon("chevron")}</button></div>
    <article class="resume-card">${cover(book.id, { flag: t("fullyDownloaded") })}<div class="resume-copy"><span class="reading-bookmark">${t("readingNow")}</span><h2>${title(book.id)}</h2><p class="chapter-name">${t("chapterNumber", { number: book.chapter })} · ${t(`book.${book.id}.chapter`)}</p><div class="progress-block"><div class="progress-copy"><span>${t("imageProgress", { page: book.page, total: book.total })}</span><span>33%</span></div>${progress(33)}</div>${button(t("resume"), "open-reader", { primary: true, symbol: "arrow", data: 'data-book="shanhai" data-chapter="12"' })}</div></article>
    <div class="section-heading"><h2>${t("recent")}</h2><button class="text-button" data-route="following">${t("viewAll")}${icon("chevron")}</button></div>
    <div class="shelf-grid">${books.slice(1).map(book => `<button class="shelf-book" data-action="open-detail" data-book="${book.id}">${cover(book.id, { flag: book.updated ? t("newChapter") : t("fullyDownloaded") })}<h3>${title(book.id)}</h3><p>${t("readToChapter", { number: book.chapter })}</p></button>`).join("")}</div>
  </main>${navigation()}`;
}
function followingScreen() {
  const filtered = books.filter(book => state.followed.has(book.id)).filter(book => state.filter === "all" || (state.filter === "updated" ? book.updated : book.finished));
  const pageSize = state.large ? 4 : 3;
  const shown = filtered.slice(state.followingPage * pageSize, (state.followingPage + 1) * pageSize);
  return `${header(t("following"))}<main class="bc-content"><div class="top-context"><span class="small-note">${t("followingCount", { count: state.followed.size })}</span><button class="text-button" data-action="refresh-library">${icon("refresh")}${t("refresh")}</button></div><div class="segmented" role="group" aria-label="${t("following")}">${[["all", "all"], ["updated", "updated"], ["finished", "complete"]].map(([key, label]) => `<button class="${state.filter === key ? "is-active" : ""}" data-action="following-filter" data-filter="${key}" aria-pressed="${state.filter === key}">${t(label)}${key === "updated" ? " 2" : ""}</button>`).join("")}</div>
    <div class="follow-list">${shown.map(book => followRow(book)).join("")}</div>${pagination(state.followingPage, Math.ceil(filtered.length / pageSize), "following-page")}</main>${navigation()}`;
}
function followRow(book, isSearch = false) {
  return `<article class="follow-row"><button class="shelf-book" data-action="open-detail" data-book="${book.id}" aria-label="${title(book.id)}">${cover(book.id)}</button><div class="follow-copy"><div class="follow-title-line"><button data-action="open-detail" data-book="${book.id}"><h2>${title(book.id)}</h2></button><span class="tag ${book.updated && !isSearch ? "solid" : ""}">${isSearch ? t(book.finished ? "complete" : "serializing") : t(book.updated ? "newChapter" : "complete")}</span></div><p>${t(`book.${book.id}.genre`)}</p><p>${t("latestChapter", { number: book.latest })} · ${t("readToChapter", { number: book.chapter })}</p><button class="text-button" data-action="${isSearch ? "open-detail" : "open-reader"}" data-book="${book.id}" data-chapter="${book.chapter}">${t(isSearch ? "chapters" : "resume")}${icon("chevron")}</button></div></article>`;
}
function chapterState(number) {
  const isOwned = number <= currentBook().ownedThrough || state.purchased.has(accessKey(state.book, number));
  const access = number <= 3 ? "free" : isOwned ? "owned" : number === 16 ? "temporary" : "locked";
  const downloaded = state.completed.some(item => item.book === state.book && number >= item.start && number <= item.end);
  const cached = downloaded ? 24 : number === 9 ? 8 : number === 11 ? 14 : 0;
  return { access, downloaded, cached, readable: access !== "locked", reading: number < currentBook().chapter ? "finishedReading" : number === currentBook().chapter ? "current" : "unread" };
}
function filteredChapters() {
  let chapters = Array.from({ length: currentBook().latest }, (_, index) => index + 1);
  chapters = chapters.filter(number => state.catalogFilter === "all" || (state.catalogFilter === "readable" ? chapterState(number).readable : chapterState(number).downloaded));
  if (state.descending) chapters.reverse();
  return chapters;
}
function detailScreen() {
  const book = currentBook();
  const list = filteredChapters();
  const firstLocked = Array.from({ length: book.latest }, (_, index) => index + 1).find(number => !chapterState(number).readable);
  const pageSize = state.large ? 8 : 5;
  const total = Math.ceil(list.length / pageSize);
  state.catalogPage = Math.max(0, Math.min(state.catalogPage, total - 1));
  const shown = list.slice(state.catalogPage * pageSize, (state.catalogPage + 1) * pageSize);
  return `${header(t(state.selecting ? "selectDownloads" : "detail"), { detail: true, back: true })}<main class="bc-content detail-content"><section class="detail-hero">${cover(book.id)}<div class="detail-copy"><div class="detail-title-row"><h2>${title(book.id)}</h2><button class="follow-toggle" data-action="toggle-follow">${state.followed.has(book.id) ? "✓ " + t("followed") : "+ " + t("follow")}</button></div><p>${t("author", { name: t(`book.${book.id}.author`) })}</p><p>${t(`book.${book.id}.genre`)} · ${t(book.finished ? "complete" : "serializing")}</p>${button(t("resumeChapter", { chapter: book.chapter }), "open-reader", { primary: true, data: `data-book="${book.id}" data-chapter="${book.chapter}"` })}</div></section>
    <div class="catalog-heading"><h3>${t("chapters")}<span>${t("chapterCount", { count: book.latest })}</span></h3><button class="text-button" data-action="toggle-sort">${t(state.descending ? "descending" : "ascending")}</button></div>
    <div class="catalog-tools"><div class="segmented compact" role="group" aria-label="${t("chapters")}">${["all", "readable", "downloaded"].map(filter => `<button data-action="catalog-filter" data-filter="${filter}" class="${state.catalogFilter === filter ? "is-active" : ""}" aria-pressed="${state.catalogFilter === filter}">${t(filter)}</button>`).join("")}</div><button class="text-button" data-action="${state.selecting ? "select-readable" : "locate-current"}">${t(state.selecting ? "selectAllReadable" : "currentChapter")}</button></div>
    <div class="episode-list">${shown.map(number => chapterRow(number)).join("")}</div>${pagination(state.catalogPage, total, "catalog-page")}
  </main>${state.selecting ? `<footer class="action-bar selection-bar"><span class="selected-label">${t("selectedCount", { count: state.selected.size })}</span>${button(t("downloadSelected", { count: state.selected.size }), "confirm-download", { primary: true, disabled: !state.selected.size })}</footer>` : `<footer class="action-bar">${button(t("downloadChapters"), "select-downloads", { symbol: "download" })}${button(t("buyChapters"), "open-purchase", { primary: true, data: `data-episode="${firstLocked || 13}"`, disabled: firstLocked === undefined })}</footer>`}`;
}
function chapterRow(number) {
  const chapter = chapterState(number);
  const reading = chapter.reading === "current" ? t("imageProgress", { page: 8, total: 24 }) : t(chapter.reading);
  const storage = chapter.downloaded ? t("fullyDownloaded") : chapter.cached ? t("partiallyCached", { count: chapter.cached, total: 24 }) : "";
  return `<article class="episode-row ${number === currentBook().chapter ? "is-current" : ""}">${state.selecting ? `<input class="episode-check" type="checkbox" aria-label="${episodeName(number)}" data-episode-check="${number}" ${state.selected.has(number) ? "checked" : ""} ${chapter.readable ? "" : "disabled"}>` : ""}<button class="episode-main" data-action="${state.selecting ? "toggle-episode" : "chapter-open"}" data-episode="${number}" ${state.selecting && !chapter.readable ? "disabled" : ""}><h4>${escape(episodeName(number))}</h4><span class="episode-meta"><span>${reading}</span><span>${t(chapter.access)}</span>${storage ? `<span class="storage-mark">${storage}</span>` : ""}</span></button>${state.selecting ? (!chapter.readable ? `<span class="small-note">${icon("lock")}</span>` : "") : `<button class="episode-action" data-action="chapter-open" data-episode="${number}" aria-label="${chapter.readable ? t("read") : t("purchase")} ${episodeName(number)}">${chapter.readable ? icon("chevron") : icon("lock") + "30"}</button>`}</article>`;
}
function searchScreen() {
  const query = state.query.trim();
  const matches = books.filter(book => !query || `${title(book.id)} ${t(`book.${book.id}.author`)} ${book.id === "shanhai" ? "36215" : ""}`.includes(query));
  return `${header(t("search"))}<main class="bc-content">${offlineBanner(t("offlineSearch"))}<form class="search-form" id="comic-search">${icon("search")}<input id="search-input" type="search" autocomplete="off" placeholder="${t("searchPlaceholder")}" aria-label="${t("searchPlaceholder")}" value="${escape(query)}"><button class="bc-button primary" type="submit">${t("search")}</button></form>${state.searched ? `<div class="section-heading"><h2>${t("searchResults", { count: matches.length })}</h2><button class="text-button" data-action="clear-search">${t("clearSearch")}</button></div>${matches.length ? `<div class="follow-list">${matches.map(book => followRow(book, true)).join("")}</div>` : `<div class="empty-state"><div class="empty-symbol">${icon("search")}</div><h2>${t("noResults")}</h2><p>${t("noResultsHint")}</p></div>`}` : `<span class="small-note">${t("recentSearches")}</span><div class="search-chips">${["shanhai", "deepsea"].map(id => `<button data-action="search-chip" data-book="${id}">${title(id)}</button>`).join("")}</div><div class="section-heading"><h2>${t("discover")}</h2></div><div class="shelf-grid">${books.slice(0, 3).map(book => `<button class="shelf-book" data-action="open-detail" data-book="${book.id}">${cover(book.id)}<h3>${title(book.id)}</h3><p>${t(`book.${book.id}.genre`)}</p></button>`).join("")}</div>`}</main>${navigation()}`;
}
function jobLabel(job) { return job.episodes ? t("selectedEpisodes", { count: job.episodes.length }) : job.start === job.end ? t("chapterNumber", { number: job.start }) : t("downloadChapterRange", { start: job.start, end: job.end }); }
function downloadsScreen() {
  const totalSize = state.completed.reduce((sum, item) => sum + item.size, 0);
  const totalChapters = state.completed.reduce((sum, item) => sum + item.end - item.start + 1, 0);
  const visibleCompleted = state.downloadListOnly ? state.completed : state.completed.slice(0, state.offline ? 1 : 2);
  return `${header(t("downloadsTitle"))}<main class="bc-content"><section class="storage-summary"><div class="storage-line"><span>${t("storageUsed")}</span><span>${t("storageFree")}</span></div><div class="storage-line"><strong>${totalSize} MB · ${t("selectedEpisodes", { count: totalChapters })}</strong></div>${progress(7)}</section>${offlineBanner(t("networkRequired"))}
    ${state.jobs.length && !state.downloadListOnly ? `<section class="download-group"><div class="download-section-title"><h2>${t("activeDownloads")} <span class="small-note">${state.jobs.length}</span></h2><span class="small-note">${t("cachedReuseHint")}</span></div>${(state.showAllJobs ? state.jobs : state.jobs.slice(0, 2)).map(job => `<article class="download-job">${cover(job.book)}<div><h3>${title(job.book)}<small class="job-range">${jobLabel(job)}</small></h3>${progress(job.done / job.total * 100)}<div class="job-status"><span>${state.offline ? t("networkRequired") : t(job.status === "running" ? "downloadRunning" : job.status === "paused" ? "downloadPaused" : "downloadFailed")}</span><span>${t("downloadProgress", { done: job.done, total: job.total })}</span></div></div><button class="job-action" data-action="toggle-job" data-job="${job.id}">${t(job.status === "running" && !state.offline ? "pause" : "resumeDownload")}</button></article>`).join("")}${state.jobs.length > 2 ? `<div class="download-view-all"><button class="text-button" data-action="toggle-all-jobs">${t(state.showAllJobs ? "back" : "viewAll")}${icon("chevron")}</button></div>` : ""}</section>` : ""}
    ${!state.showAllJobs ? `<section><div class="download-section-title"><h2>${t("downloadedItems")}</h2><button class="text-button" data-action="manage-downloads">${state.manageDownloads ? t("cancel") : t("manageDownloads")}</button></div>${state.completed.length ? visibleCompleted.map(item => `<article class="download-job completed">${cover(item.book)}<div><h3>${title(item.book)}</h3><p>${jobLabel(item)} · ${item.size} MB · ${t("offlineReadable")}</p></div><button class="text-button" data-action="${state.manageDownloads ? "remove-download" : "read-downloaded"}" data-saved="${item.id}">${t(state.manageDownloads ? "removeDownload" : "read")}${icon("chevron")}</button></article>`).join("") : `<div class="empty-state"><div class="empty-symbol">${icon("download")}</div><h2>${t("emptyDownloads")}</h2><p>${t("emptyDownloadsHint")}</p>${button(t("goFollowing"), "go-following")}</div>`}${state.completed.length > 2 || state.downloadListOnly ? `<div class="download-view-all"><button class="text-button" data-action="toggle-download-list">${t(state.downloadListOnly ? "back" : "viewAll")}${icon("chevron")}</button></div>` : ""}</section>` : ""}
  </main>${navigation()}`;
}
function settingsScreen() {
  return `${header(t("settings"), { back: true, detail: true })}<main class="bc-content"><section class="account-card"><div class="avatar">${icon("user")}</div><div><h2>${t("accountName")}</h2><p>${t("sessionActive")}</p></div></section><div class="wallet-grid"><div><span>${t("coins")}</span><strong>${state.balance}</strong></div><div><span>${t("coupons")}</span><strong>${state.coupons}</strong></div></div><button class="settings-row" data-action="session-info"><strong>${t("replaceSession")}</strong>${icon("chevron")}</button><h2 class="settings-heading">${t("readingSettings")}</h2><button class="settings-row" data-action="toggle-prefetch" role="switch" aria-checked="${state.prefetch}"><span><strong>${t("prefetchSetting")}</strong><small>${t("prefetchHint")}</small></span><span class="toggle-track ${state.prefetch ? "on" : ""}" aria-hidden="true"></span></button><button class="settings-row" data-action="reader-setting"><strong>${t("stripSetting")}</strong><span class="settings-value">${t("stripValue")}${icon("chevron")}</span></button><h2 class="settings-heading">${t("cacheSettings")}</h2><button class="settings-row" data-action="cache-setting"><strong>${t("autoCache")}</strong><span class="settings-value">${t("autoCacheValue")}${icon("chevron")}</span></button><button class="settings-row" data-action="clear-cache"><span><strong>${t("clearAutoCache")}</strong><small>${t("clearAutoHint")}</small></span>${icon("chevron")}</button></main>${navigation()}`;
}
function readerScreen() {
  const book = currentBook();
  const downloadable = state.completed.some(item => item.book === state.book && state.readerChapter >= item.start && state.readerChapter <= item.end);
  const missing = state.offline && !downloadable && state.readerPage > 10;
  return `<div class="reader-header"><span>${title(book.id)} · ${t("chapterNumber", { number: state.readerChapter })}</span><button class="icon-button" data-action="reader-menu" aria-label="${t("readerMenuTitle")}">${icon("more")}</button></div><main class="reader-surface" data-action="reader-menu" aria-label="${t("readerTapHint")}">${missing ? `<div class="empty-state"><div class="empty-symbol">${icon("offline")}</div><h2>${t("offlineMissing")}</h2><p>${t("offlineMissingHint")}</p>${button(t("backDownloaded"), "go-downloads")}</div>` : `<img class="reader-art" src="${asset("reader-page")}" alt="${t("readerContext")}" style="margin-top:-${state.readerPage % 3 * 70 + 20}px">`}</main><div class="reader-caption"><span>${t("imageProgress", { page: state.readerPage, total: 24 })}</span><span>${state.offline ? t(downloadable ? "offlineReaderStatus" : "offlineCacheStatus") : state.prefetch ? t("prefetchStatus") : ""}</span></div><footer class="reader-paging"><button class="icon-button" data-action="reader-prev" aria-label="${t("previousImage")}">${icon("back")}</button><div class="native-progress">${progress(state.readerPage / 24 * 100)}<span>${state.readerPage} / 24</span></div><button class="icon-button" data-action="reader-next" aria-label="${t("nextImage")}">${icon("chevron")}</button></footer>`;
}
function dialog(titleText, body, className = "") {
  return `<div class="modal-backdrop"><section class="bc-modal ${className}" role="dialog" aria-modal="true" aria-labelledby="modal-title"><header class="modal-header"><h2 id="modal-title" tabindex="-1">${escape(titleText)}</h2><button class="icon-button" data-action="close-modal" aria-label="${t("close")}">${icon("close")}</button></header><div class="modal-body">${body}</div></section></div>`;
}
function price() { return state.purchaseMode === "batch" ? state.batchCount === 5 ? 135 : 240 : 30; }
function purchaseDialog() {
  const amount = price();
  const balance = state.scenario === "low" ? 12 : state.balance;
  const insufficient = state.method === "coins" && balance < amount;
  const isSingle = state.purchaseMode === "single";
  const phase = state.purchasePhase;
  if (["unknown", "success", "loadfail"].includes(phase)) {
    const phaseCopy = { unknown: ["unknownTitle", "unknownBody", "refreshEntitlement", "refresh-purchase", "clock"], success: ["purchaseSuccess", "purchaseSuccessBody", "resume", "purchase-read", "check"], loadfail: ["loadFailedTitle", "loadFailedBody", "retryLoading", "purchase-read", "alert"] }[phase];
    return dialog(t("purchase"), `<div class="purchase-state"><div class="state-symbol">${icon(phaseCopy[4])}</div><h3>${phase === "success" && !isSingle ? t("purchaseBatchSuccess", { count: state.batchCount }) : t(phaseCopy[0])}</h3><p>${t(phaseCopy[1])}</p>${button(t(phaseCopy[2]), phaseCopy[3], { primary: true, className: "block" })}${phase === "success" ? button(isSingle ? t("downloadThisChapter") : t("downloadSelected", { count: state.batchCount }), "purchase-download", { className: "block" }) : button(t("changeSelection"), "close-modal", { className: "block subtle" })}${phase === "unknown" ? `<p class="purchase-footer-note">${t("unknownKeep")}</p>` : ""}</div>`);
  }
  return dialog(t("purchase"), `<div class="purchase-book">${cover(state.book)}<div><h3>${title(state.book)}</h3><p>${isSingle ? escape(episodeName(state.purchaseEpisode)) : t(state.batchCount === 5 ? "fiveChapters" : "tenChapters")}</p></div></div><div class="purchase-tabs" role="group" aria-label="${t("purchaseRange")}"><button data-action="purchase-mode" data-mode="single" class="${isSingle ? "is-active" : ""}" aria-pressed="${isSingle}" ${phase === "pending" ? "disabled" : ""}>${t("singlePurchase")}</button><button data-action="purchase-mode" data-mode="batch" class="${!isSingle ? "is-active" : ""}" aria-pressed="${!isSingle}" ${phase === "pending" ? "disabled" : ""}>${t("batchPurchase")}</button></div>${!isSingle ? `<label class="field-label" for="purchase-range">${t("purchaseRange")}</label><select class="purchase-select" id="purchase-range" ${phase === "pending" ? "disabled" : ""}><option value="5" ${state.batchCount === 5 ? "selected" : ""}>${t("fiveChapters")} · 135 ${t("coins")}</option><option value="10" ${state.batchCount === 10 ? "selected" : ""}>${t("tenChapters")} · 240 ${t("coins")}</option></select>` : ""}<p class="field-label">${t("paymentMethod")}</p>
    <label class="payment-option ${state.method === "coins" ? "is-selected" : ""}"><input type="radio" name="payment-method" value="coins" ${state.method === "coins" ? "checked" : ""} ${phase === "pending" ? "disabled" : ""}><span class="payment-copy"><strong>${t("coins")}</strong><small>${t("balance", { count: balance })}</small></span><span class="payment-price">${amount} ${t("coins")}</span></label>
    ${isSingle ? `<label class="payment-option ${state.method === "coupons" ? "is-selected" : ""}"><input type="radio" name="payment-method" value="coupons" ${state.method === "coupons" ? "checked" : ""} ${state.coupons < 1 || phase === "pending" ? "disabled" : ""}><span class="payment-copy"><strong>${t("coupons")}</strong><small>${t("availableCoupons", { count: state.coupons })}</small></span><span class="payment-price">${t("couponCount", { count: 1 })}</span></label>` : ""}
    <div class="quote-total"><div><p>${t("permanentAccess")} · ${t("selectedEpisodes", { count: isSingle ? 1 : state.batchCount })}</p><small>${t("total")}${!isSingle ? " · " + t("discount") : ""}</small></div><strong>${state.method === "coins" ? amount : 1}<span>${t(state.method === "coins" ? "coins" : "coupons")}</span></strong></div>
    ${insufficient ? `<div class="purchase-shortfall">${t("insufficient")}，${t("shortfall", { count: amount - balance })}</div>` : ""}
    ${button(t(state.offline ? "offlinePurchase" : phase === "pending" ? "paying" : state.method === "coins" ? "payCoins" : "payCoupon", { count: amount }), "submit-purchase", { primary: true, className: "block", disabled: insufficient || state.offline || phase === "pending" })}
    ${insufficient ? `<button class="text-button" style="display:flex;margin:5px auto 0" data-action="refresh-balance">${icon("refresh")}${t("refreshBalance")}</button>` : `<p class="purchase-footer-note">${state.method === "coins" ? t("afterBalance", { count: balance - amount }) : t("quoteHint")}</p>`}`);
}
function readerMenuDialog() {
  const rows = [["chapterCatalog", "reader-catalog", "list"], ["detail", "reader-detail", "book"], ["downloadThisChapter", "reader-download", "download"], ["nextChapter", "reader-next-chapter", "arrow"], ["returnLibrary", "reader-library", "grid"]];
  return dialog(t("readerMenuTitle"), `<p class="native-controls-row">${t("nativeControls")}</p>${rows.map(([label, action, symbol]) => `<button class="reader-menu-action" data-action="${action}"><span>${icon(symbol)}${t(label)}</span>${icon("chevron")}</button>`).join("")}`, "reader-menu");
}
function modalMarkup() {
  if (state.modal === "purchase") return purchaseDialog();
  if (state.modal === "reader-menu") return readerMenuDialog();
  if (state.modal === "chapter-end") return dialog(t("chapterEnd"), `<div class="purchase-state"><div class="state-symbol">${icon("book")}</div><h3>${escape(episodeName(state.readerChapter + 1))}</h3><p>${t(chapterState(state.readerChapter + 1).readable ? "readNextChapter" : "nextChapterLocked")}</p>${button(t(chapterState(state.readerChapter + 1).readable ? "readNextChapter" : "purchaseNext"), "continue-next-chapter", { primary: true, className: "block" })}${button(t("returnLibrary"), "reader-library", { className: "block subtle" })}</div>`);
  if (state.modal === "remove") return dialog(t("removeTitle"), `<div class="purchase-state"><p>${t("removeBody")}</p>${button(t("removeDownload"), "confirm-remove", { primary: true, className: "block" })}${button(t("cancel"), "close-modal", { className: "block subtle" })}</div>`);
  return "";
}
function render() {
  const focusedId = document.activeElement?.id;
  document.title = t("pageTitle");
  document.body.classList.toggle("is-embed", embed);
  const route = activeRoute();
  const screen = { continue: continueScreen, following: followingScreen, detail: detailScreen, search: searchScreen, downloads: downloadsScreen, settings: settingsScreen, reader: readerScreen }[state.view] || continueScreen;
  const flowItems = [["continue", "continueTitle", "book"], ["following", "following", "bookmark"], ["detail", "detail", "list"], ["purchase", "purchase", "wallet"], ["downloads", "downloadsTitle", "download"], ["reader", "reader", "book"], ["settings", "settings", "settings"]];
  const note = { continue: "Continue", following: "Following", detail: "Detail", purchase: "Purchase", downloads: "Downloads", search: "Search", reader: "Reader", settings: "Settings" }[route];
  root.innerHTML = `<div class="lab ${state.large ? "is-large" : ""}"><header class="lab-top"><div class="lab-brand"><span class="brand-mark" aria-hidden="true"></span><span>${t("labEyebrow")}</span></div><div class="lab-tools"><button class="lab-tool ${!state.large ? "is-active" : ""}" data-action="set-size" data-size="standard">${t("standardSize")}</button><button class="lab-tool ${state.large ? "is-active" : ""}" data-action="set-size" data-size="large">${t("largeSize")}</button><button class="lab-tool" data-action="toggle-network" aria-label="${t(state.offline ? "onlineMode" : "offlineMode")}">${icon(state.offline ? "offline" : "wifi")}${t(state.offline ? "offline" : "online")}</button><button class="lab-tool" data-action="reset">${icon("refresh")}${t("reset")}</button></div></header>
    ${route === "purchase" ? `<label class="compact-scenario">${t("scenario")}<select id="purchase-scenario-compact">${[["normal", "normalScenario"], ["low", "lowScenario"], ["unknown", "unknownScenario"], ["loadfail", "loadFailureScenario"]].map(([key, label]) => `<option value="${key}" ${state.scenario === key ? "selected" : ""}>${t(label)}</option>`).join("")}</select></label>` : ""}
    <div class="lab-stage"><aside class="lab-intro"><h1 class="lab-title">${t("labTitle")}</h1><p class="lab-description">${t("labIntro")}</p><div class="lab-caption">${t("labNavigation")}</div><nav class="flow-nav" aria-label="${t("labNavigation")}">${flowItems.map(([key, label, symbol]) => `<button data-route="${key}" class="${route === key ? "is-active" : ""}" ${route === key ? 'aria-current="page"' : ""}>${icon(symbol)}${t(label)}</button>`).join("")}</nav><p class="lab-hint">${t("labHint")}</p></aside>
    <div class="device-column"><div class="device-caption"><span>${t("deviceLabel")}</span><span>${state.large ? "768 × 1024" : "600 × 800"}</span></div><div class="device-frame"><div class="device-screen" data-screen="${state.view}" aria-label="${t("pageTitle")}">${statusBar()}${screen()}${modalMarkup()}${state.toast ? `<div class="toast" role="status">${escape(state.toast)}</div>` : ""}</div><div class="device-chin">B I L I C O M I C S</div></div></div>
    <aside class="lab-notes"><div class="note-rule"></div><h2 class="note-title">${t(`note${note}Title`)}</h2><p class="note-copy">${t(`note${note}`)}</p><div class="note-fact"><span>${t("layoutLabel")}</span><span>${t("layoutValue")}</span></div><div class="note-fact"><span>${t("interactionLabel")}</span><span>${t("interactionValue")}</span></div>${route === "purchase" ? `<label class="scenario-field">${t("scenario")}<select id="purchase-scenario">${[["normal", "normalScenario"], ["low", "lowScenario"], ["unknown", "unknownScenario"], ["loadfail", "loadFailureScenario"]].map(([key, label]) => `<option value="${key}" ${state.scenario === key ? "selected" : ""}>${t(label)}</option>`).join("")}</select></label>` : ""}${route === "reader" ? `<p class="subtle-native-note">${t("readerNote")}</p>` : ""}</aside></div><footer class="lab-footer">${t("labFoot")}</footer></div>`;
  const nextParams = new URLSearchParams(location.search);
  nextParams.set("view", route);
  if (route === "purchase") nextParams.set("scenario", state.scenario); else nextParams.delete("scenario");
  window.history.replaceState(null, "", `${location.pathname}?${nextParams}`);
  if (state.modal && state.modal !== lastModal) document.getElementById("modal-title")?.focus({ preventScroll: true });
  else if (focusedId) document.getElementById(focusedId)?.focus({ preventScroll: true });
  lastModal = state.modal;
}
function notify(message) {
  clearTimeout(toastTimer);
  state.toast = message;
  render();
  toastTimer = setTimeout(() => { state.toast = ""; render(); }, 2400);
}
function navigate(view) {
  state.modal = null;
  state.selecting = false;
  state.toast = "";
  if (view === "purchase") {
    state.view = "detail";
    state.book = "shanhai";
    openPurchase(13);
    return;
  }
  state.view = view;
  render();
}
function openPurchase(episode = 13) {
  const pending = state.transaction;
  if (pending && ["pending", "unknown"].includes(pending.status)) {
    state.book = pending.book;
    state.purchaseEpisode = pending.episode;
    state.purchaseMode = pending.mode;
    state.batchCount = pending.count;
    state.method = pending.method;
    state.purchasePhase = pending.status;
    state.modal = "purchase";
    render();
    return;
  }
  state.purchaseEpisode = episode;
  state.purchaseMode = "single";
  state.method = "coins";
  state.purchasePhase = state.purchased.has(accessKey(state.book, episode)) ? "success" : "quote";
  state.modal = "purchase";
  render();
}
function setScenario(scenario) {
  clearTimeout(purchaseTimer);
  state.transaction = null;
  state.scenario = scenario;
  state.purchasePhase = scenario === "unknown" ? "unknown" : scenario === "loadfail" ? "loadfail" : "quote";
  if (scenario === "loadfail") state.purchased.add(accessKey(state.book, state.purchaseEpisode));
  if (scenario === "unknown") state.transaction = transactionSnapshot("unknown");
  render();
}
function openReader(book = state.book, chapter = 12) {
  state.book = book;
  state.readerChapter = chapter;
  state.readerPage = chapter === 12 ? 8 : 1;
  state.view = "reader";
  state.modal = null;
  state.toast = "";
  render();
}
function transactionSnapshot(status) {
  return { book: state.book, episode: state.purchaseEpisode, count: state.purchaseMode === "batch" ? state.batchCount : 1,
    start: state.purchaseMode === "batch" ? 13 : state.purchaseEpisode, mode: state.purchaseMode, method: state.method, amount: price(), status };
}
function confirmAccess(transaction = state.transaction || transactionSnapshot("accepted")) {
  const { count, start, book, method, amount } = transaction;
  const hasAccess = Array.from({ length: count }, (_, index) => start + index).every(number => state.purchased.has(accessKey(book, number)));
  if (!hasAccess) {
    if (method === "coins") state.balance = Math.max(0, state.balance - amount); else state.coupons = Math.max(0, state.coupons - 1);
    for (let index = 0; index < count; index++) state.purchased.add(accessKey(book, start + index));
  }
  transaction.status = "success";
}
root.addEventListener("click", event => {
  const target = event.target.closest("[data-action], [data-route]");
  if (!target || target.disabled) return;
  if (target.dataset.route) { navigate(target.dataset.route); return; }
  const action = target.dataset.action;
  const number = Number(target.dataset.episode);
  switch (action) {
    case "back": if (state.selecting) state.selecting = false; else state.view = state.view === "settings" ? "continue" : "following"; break;
    case "set-size": state.large = target.dataset.size === "large"; break;
    case "toggle-network": state.offline = !state.offline; break;
    case "reset": clearTimeout(purchaseTimer); state = initialState(); break;
    case "open-detail": state.book = target.dataset.book; state.view = "detail"; state.catalogPage = 2; state.catalogFilter = "all"; break;
    case "open-reader": openReader(target.dataset.book || state.book, Number(target.dataset.chapter || 12)); return;
    case "show-updates": state.filter = "updated"; state.followingPage = 0; state.view = "following"; break;
    case "following-filter": state.filter = target.dataset.filter; state.followingPage = 0; break;
    case "following-page": state.followingPage += Number(target.dataset.direction); break;
    case "refresh-library": notify(t("followingCount", { count: state.followed.size })); return;
    case "toggle-follow": if (state.followed.has(state.book)) state.followed.delete(state.book); else state.followed.add(state.book); notify(t(state.followed.has(state.book) ? "followedToast" : "unfollowedToast")); return;
    case "toggle-sort": state.descending = !state.descending; state.catalogPage = 0; break;
    case "catalog-filter": state.catalogFilter = target.dataset.filter; state.catalogPage = 0; break;
    case "catalog-page": state.catalogPage += Number(target.dataset.direction); break;
    case "locate-current": state.catalogFilter = "all"; state.descending = false; state.catalogPage = Math.floor((currentBook().chapter - 1) / (state.large ? 8 : 5)); break;
    case "chapter-open": if (chapterState(number).readable) openReader(state.book, number); else openPurchase(number); return;
    case "select-downloads": state.selecting = true; state.selected.clear(); break;
    case "toggle-episode": if (chapterState(number).readable) { if (state.selected.has(number)) state.selected.delete(number); else state.selected.add(number); } break;
    case "select-readable": {
      const size = state.large ? 8 : 5;
      filteredChapters().slice(state.catalogPage * size, (state.catalogPage + 1) * size).filter(number => chapterState(number).readable).forEach(number => state.selected.add(number));
      break;
    }
    case "confirm-download": {
      if (!state.selected.size) return;
      const selected = [...state.selected].sort((a, b) => a - b);
      const missing = selected.filter(number => !chapterState(number).downloaded);
      if (missing.length) state.jobs.unshift({ id: `job-${Date.now()}`, book: state.book, episodes: missing, start: missing[0], end: missing.at(-1), done: 0, total: missing.length * 24, status: state.offline ? "paused" : "running" });
      state.selecting = false; state.view = "downloads"; notify(t("downloadQueued")); return;
    }
    case "open-purchase": openPurchase(number || 13); return;
    case "close-modal": state.modal = null; state.readerMenu = false; break;
    case "purchase-mode": state.purchaseMode = target.dataset.mode; state.method = "coins"; state.purchasePhase = "quote"; break;
    case "submit-purchase": {
      if (state.purchasePhase !== "quote" || state.offline || (state.method === "coins" && (state.scenario === "low" ? 12 : state.balance) < price())) return;
      state.purchasePhase = "pending";
      const transaction = transactionSnapshot("pending");
      state.transaction = transaction;
      purchaseTimer = setTimeout(() => {
        if (state.scenario === "unknown") { transaction.status = "unknown"; state.purchasePhase = "unknown"; }
        else { confirmAccess(transaction); state.purchasePhase = state.scenario === "loadfail" ? "loadfail" : "success"; }
        render();
      }, 650);
      break;
    }
    case "refresh-balance": state.scenario = "normal"; state.balance = Math.max(300, state.balance); state.purchasePhase = "quote"; break;
    case "refresh-purchase": confirmAccess(); state.purchasePhase = "success"; break;
    case "purchase-read": openReader(state.book, state.purchaseMode === "batch" ? 13 : state.purchaseEpisode); return;
    case "purchase-download": state.jobs.unshift({ id: `job-${Date.now()}`, book: state.book, start: state.purchaseMode === "batch" ? 13 : state.purchaseEpisode, end: state.purchaseMode === "batch" ? 12 + state.batchCount : state.purchaseEpisode, done: 0, total: (state.purchaseMode === "batch" ? state.batchCount : 1) * 24, status: "running" }); state.modal = null; state.view = "downloads"; notify(t("downloadQueued")); return;
    case "toggle-job": {
      const job = state.jobs.find(item => item.id === target.dataset.job);
      if (state.offline) { notify(t("networkRequired")); return; }
      if (job) { job.status = job.status === "running" ? "paused" : "running"; if (job.status === "running") job.done = Math.min(job.total - 1, job.done + 3); }
      break;
    }
    case "manage-downloads": state.manageDownloads = !state.manageDownloads; break;
    case "toggle-download-list": state.downloadListOnly = !state.downloadListOnly; state.showAllJobs = false; break;
    case "toggle-all-jobs": state.showAllJobs = !state.showAllJobs; break;
    case "read-downloaded": { const item = state.completed.find(item => item.id === target.dataset.saved); if (item) openReader(item.book, item.start); return; }
    case "remove-download": state.removeId = target.dataset.saved; state.modal = "remove"; break;
    case "confirm-remove": state.completed = state.completed.filter(item => item.id !== state.removeId); state.modal = null; notify(t("removedToast")); return;
    case "search-chip": state.query = title(target.dataset.book); state.searched = true; break;
    case "clear-search": state.query = ""; state.searched = false; break;
    case "reader-menu": state.modal = "reader-menu"; break;
    case "reader-prev": state.readerPage = Math.max(1, state.readerPage - 1); break;
    case "reader-next": if (state.readerPage >= 24) state.modal = "chapter-end"; else state.readerPage += 1; break;
    case "reader-next-chapter": state.modal = "chapter-end"; break;
    case "continue-next-chapter": if (chapterState(state.readerChapter + 1).readable) openReader(state.book, state.readerChapter + 1); else openPurchase(state.readerChapter + 1); return;
    case "reader-detail": case "reader-catalog": state.modal = null; state.view = "detail"; state.catalogPage = Math.floor((state.readerChapter - 1) / (state.large ? 8 : 5)); break;
    case "reader-download": state.modal = null; state.jobs.unshift({ id: `job-${Date.now()}`, book: state.book, start: state.readerChapter, end: state.readerChapter, done: 8, total: 24, status: state.offline ? "paused" : "running" }); notify(t("downloadQueued")); return;
    case "reader-library": state.modal = null; state.view = "continue"; break;
    case "go-following": state.view = "following"; break;
    case "go-downloads": state.modal = null; state.view = "downloads"; break;
    case "toggle-prefetch": state.prefetch = !state.prefetch; break;
    case "session-info": notify(t("sessionDemo")); return;
    case "reader-setting": notify(t("stripValue")); return;
    case "cache-setting": notify(t("autoCacheValue")); return;
    case "clear-cache": notify(t("cacheCleared")); return;
    default: return;
  }
  render();
});
root.addEventListener("change", event => {
  const input = event.target;
  if (input.id === "purchase-scenario" || input.id === "purchase-scenario-compact") { setScenario(input.value); return; }
  if (input.id === "purchase-range") { state.batchCount = Number(input.value); state.purchasePhase = "quote"; }
  else if (input.name === "payment-method") state.method = input.value;
  else if (input.dataset.episodeCheck) {
    const number = Number(input.dataset.episodeCheck);
    if (input.checked) state.selected.add(number); else state.selected.delete(number);
  } else return;
  render();
});
root.addEventListener("submit", event => {
  if (event.target.id !== "comic-search") return;
  event.preventDefault();
  state.query = document.getElementById("search-input").value;
  state.searched = true;
  render();
});
document.addEventListener("keydown", event => {
  if (event.key === "Escape" && state.modal) { state.modal = null; render(); }
  if (event.key === "Tab" && state.modal) {
    const controls = [...root.querySelectorAll('[role="dialog"] button:not(:disabled), [role="dialog"] input:not(:disabled), [role="dialog"] select')];
    const first = controls[0], last = controls.at(-1);
    if (!controls.includes(document.activeElement)) { event.preventDefault(); (event.shiftKey ? last : first)?.focus(); }
    else if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus(); }
    else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus(); }
  }
});
const startView = params.get("view");
if (["continue", "following", "detail", "purchase", "search", "downloads", "settings", "reader"].includes(startView)) {
  state.view = startView === "purchase" ? "detail" : startView;
  if (startView === "purchase") state.modal = "purchase";
}
if (params.get("offline") === "1") state.offline = true;
if (params.get("size") === "large") state.large = true;
if (state.modal === "purchase" && ["low", "unknown", "loadfail"].includes(params.get("scenario"))) {
  state.scenario = params.get("scenario");
  state.purchasePhase = state.scenario === "unknown" ? "unknown" : state.scenario === "loadfail" ? "loadfail" : "quote";
  if (state.scenario === "unknown") state.transaction = transactionSnapshot("unknown");
  if (state.scenario === "loadfail") state.purchased.add(accessKey(state.book, state.purchaseEpisode));
}
render();
window.__prototypeReady = true;
