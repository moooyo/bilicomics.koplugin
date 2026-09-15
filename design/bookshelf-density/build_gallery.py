"""Build an offline native screenshot review gallery from remote captures."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil

from PIL import Image, ImageDraw, ImageFont, ImageOps


OPTIMIZED_TITLES = {
    "comic-overview": "漫画完整信息与简介",
    "chapter-filter-menu": "章节筛选菜单",
    "chapter-jump-input": "按章节序号或标题跳转",
    "chapter-jump-no-match": "跳转 · 没有匹配章节",
    "chapter-jump-results": "跳转 · 匹配章节",
    "chapter-actions": "章节阅读与下载操作",
    "chapter-page-picker": "章节跳转 · 分页入口",
    "chapter-selection-menu": "下载选择范围",
    "chapter-selected-review": "查看已选章节",
    "chapter-selected-summary": "查看已选章节",
    "download-filter-menu": "下载状态筛选",
    "account-other-sign-in-methods": "其他登录方式",
    "account-storage-and-cache": "存储与缓存管理",
    "account-cache-limit-options": "自动缓存上限选择",
    "account-cache-limit-reduction": "调低缓存上限确认",
    "account-cache-cleanup-result": "缓存清理结果",
    "account-preload-options": "预加载张数选择",
    "account-preload-saved": "预加载设置已保存",
    "account-reader-defaults": "新章节默认阅读设置",
    "account-stale-pending-import-result": "账户 · 余额、待核对购买与导入结果",
    "account-session-import-result": "账户 · 会话导入结果",
    "session-validating-background-option": "会话导入 · 后台处理说明",
    "search-filter-menu": "搜索筛选菜单",
    "search-return-to-history": "返回最近搜索",
    "search-history-cleared": "搜索历史已清空",
    "search-history-loading": "从历史发起搜索",
    "search-history-results": "历史搜索结果",
    "search-return-context": "搜索 · 返回后保留筛选与位置",
    "empty-search": "搜索 · 无匹配结果",
    "empty-downloads": "下载 · 空列表",
    "cross-page-download-selection": "下载选择 · 跨页范围",
    "expired-quote": "报价已过期",
    "pending-result-network-recovery": "购买结果核对 · 网络恢复",
}

GROUPS = [
    {"id": "bookshelf", "title": "书架", "caption": "Bookshelf", "symbol": "▤"},
    {"id": "bookstore", "title": "书城", "caption": "Bookstore", "symbol": "▥"},
    {"id": "search", "title": "搜索", "caption": "Search", "symbol": "⌕"},
    {"id": "chapters", "title": "章节", "caption": "Chapters", "symbol": "≡"},
    {"id": "downloads", "title": "下载", "caption": "Downloads", "symbol": "↓"},
    {"id": "account", "title": "账户与登录", "caption": "Account and sign-in", "symbol": "○"},
    {"id": "purchase", "title": "购买", "caption": "Purchases", "symbol": "◇"},
    {"id": "reader", "title": "阅读器", "caption": "Reader", "symbol": "▣"},
]
GROUP_ORDER = {group["id"]: index for index, group in enumerate(GROUPS)}
IGNORED_DIRECTORIES = {"fixtures", "home", "ko_home", "profile", "screens", "thumbnails", "assets"}
DIMENSIONS = re.compile(r"(?:(zh_CN|zh-CN|C|en|en_US)-)?(\d{3,4})x(\d{3,4})$")
CHINESE_SUITES = {"native", "session-import", "review-supplement", "review-reader", "qr-login", "download-recovery", "version-replacement", "quote-selection", "ordinal-range", "entitlement-display"}

TITLES = {
    "bookshelf": "书架 · 默认页面", "following": "书架 · 追更列表", "chapters": "漫画详情与章节", "search": "搜索 · 默认页面", "downloads": "下载管理", "account": "账户与设置",
    "bookshelf-finishing-default": "书架 · 默认页面", "bookshelf-finishing-more": "书架 · 更多操作", "bookshelf-finishing-filter": "书架 · 筛选菜单", "bookshelf-finishing-help": "书架 · 使用帮助",
    "bookshelf-finishing-offline-cache": "书架 · 离线缓存", "bookshelf-finishing-initial-sync": "书架 · 首次同步", "bookshelf-finishing-confirmed-empty": "书架 · 已确认无内容", "bookshelf-finishing-filter-empty": "书架 · 筛选无结果", "bookshelf-finishing-anonymous": "书架 · 未登录",
    "bookshelf-finishing-authenticated-offline-cache": "书架 · 已登录且离线有缓存", "bookshelf-finishing-authenticated-offline-more": "书架 · 离线更多操作", "bookshelf-finishing-authenticated-offline-empty": "书架 · 已登录且离线无缓存", "bookshelf-finishing-sync-unavailable": "书架 · 暂不可同步", "bookshelf-finishing-sync-unavailable-more": "书架 · 不可同步时的更多操作", "bookshelf-finishing-category": "书架 · 分类", "bookshelf-finishing-concurrency": "书架 · 下载并发设置",
    "bookstore-categories-picker": "书城 · 分类选择", "bookstore-categories-loaded": "书城 · 分类内容", "bookstore-categories-picker-refreshed": "书城 · 分类已刷新", "bookstore-categories-appended": "书城 · 追加内容", "bookstore-categories-server-end": "书城 · 已到最后一页", "bookstore-categories-cache-limit": "书城 · 达到缓存上限", "bookstore-categories-synopsis": "书城 · 漫画简介", "bookstore-categories-chapters": "从书城进入章节",
    "bookstore-expanded-recommendations": "书城 · 推荐页面", "bookstore-recommendations": "书城 · 推荐页面", "bookstore-expanded-synopsis": "书城 · 漫画简介", "bookstore-expanded-chapters": "书城 · 漫画章节",
    "follow-pending": "章节 · 正在更新追漫状态", "download-selection": "章节 · 选择下载", "account-pending": "账户 · 存在待确认购买", "reader-defaults": "阅读默认设置", "local-diagnostics": "本地诊断", "comic-id-input": "按漫画 ID 打开",
    "purchase": "购买 · 单章确认", "purchase-batch": "购买 · 批量确认", "purchase-unknown": "购买 · 结果未知", "purchase-confirmed": "购买 · 已确认成功", "purchase-low-balance": "购买 · 余额不足", "locked-download-action": "未解锁章节 · 下载操作", "purchase-download": "购买后继续下载", "download-access-confirmed": "下载 · 已确认阅读权限", "download-continuation-retry": "下载 · 继续任务失败后重试",
    "qr-account-signed-out": "账户 · 未登录", "qr-loading": "扫码登录 · 正在加载", "qr-waiting": "扫码登录 · 等待扫码", "qr-scanned": "扫码登录 · 等待手机确认", "qr-expired": "扫码登录 · 二维码已过期", "qr-account-renewable": "账户 · 会话可续期", "qr-account-maintenance": "账户 · 会话维护", "qr-account-renewal-error": "账户 · 续期失败", "qr-account-reauthentication": "账户 · 需要重新登录", "qr-error": "扫码登录 · 请求失败",
    "session-file-picker": "导入会话 · 选择文件", "session-file-validating": "导入会话 · 正在验证", "session-file-imported": "导入会话 · 导入成功", "session-file-error": "导入会话 · 文件错误", "session-masked-input": "导入会话 · 敏感字段遮罩",
    "failed-download": "下载 · 任务失败", "recovery-options": "下载 · 恢复选项", "refresh-confirmation": "下载 · 刷新确认", "fetching-sources": "下载 · 正在获取图片源", "verifying-history": "下载 · 正在核对已有内容", "verification-canceled": "下载 · 核对已取消", "paused-download": "下载 · 已暂停", "verification-complete": "下载 · 核对完成", "canceled-download": "下载 · 已取消", "remove-during-verification": "下载 · 核对期间移除", "removed-download": "下载 · 已移除", "stale-account-feedback": "下载 · 账户状态已变化",
    "replacement-confirmation": "版本替换 · 确认", "preparing-new-version": "版本替换 · 准备新版本", "preparation-canceled": "版本替换 · 准备已取消", "old-and-new-versions": "版本替换 · 新旧版本并存", "new-version-queue": "版本替换 · 新版本进入队列", "source-verification-controls": "版本替换 · 图片源核对操作",
    "remaining-range-option": "购买 · 剩余章节范围", "single-unchanged": "购买 · 单章报价未变化", "changed-price-needs-confirmation": "购买 · 价格变化需重新确认", "range-outcome-pending": "购买 · 批量结果待确认", "pending-purchase-list": "待确认的购买记录", "coupon-snapshot-details": "购买 · 券资产详情", "insufficient-balance": "购买 · 余额不足", "single-confirmation": "购买 · 单章确认", "submission-result": "购买 · 提交结果",
    "temporary-first-page": "章节 · 临时权益首页", "temporary-current-chapter": "章节 · 当前临时权益", "ordinary-first-page": "章节 · 普通权益首页", "ordinary-current-chapter": "章节 · 当前普通权益",
    "bookshelf-sort": "书架 · 排序菜单", "bookshelf-updated-filter": "书架 · 只看更新", "bookshelf-completed-filter": "书架 · 只看已完结", "search-empty-history": "搜索 · 无历史记录", "search-recent-history": "搜索 · 最近搜索", "search-input-keyboard": "搜索 · 输入与键盘", "search-loading": "搜索 · 正在加载", "search-results": "搜索 · 结果列表", "search-results-next-page": "搜索 · 结果下一页", "search-ongoing-filter": "搜索 · 连载筛选", "search-completed-filter": "搜索 · 完结筛选", "search-no-results": "搜索 · 无结果", "comic-id-keyboard": "按漫画 ID 打开 · 键盘", "comic-id-error": "按漫画 ID 打开 · 错误反馈",
    "chapters-unread-filter": "章节 · 未读筛选", "chapters-downloaded-filter": "章节 · 已下载筛选", "chapters-newest-first": "章节 · 最新在前", "chapters-selection-empty": "章节 · 尚未选择下载", "chapters-selection-selected": "章节 · 已选择下载", "chapters-empty": "章节 · 暂无内容", "downloads-active-filter": "下载 · 进行中筛选", "downloads-ready-offline": "下载 · 可离线阅读", "download-remove-confirmation": "下载 · 移除确认", "downloads-empty": "下载 · 暂无任务",
    "cache-clear-confirmation": "账户 · 清理自动缓存确认", "diagnostics-loading": "本地诊断 · 正在加载", "diagnostics-mixed-capabilities": "本地诊断 · 部分能力可用", "account-stale-balance": "账户 · 余额已过期", "purchase-quote-loading": "购买 · 正在加载报价", "purchase-quote-error": "购买 · 报价失败", "purchase-submitting": "购买 · 正在提交", "purchase-rejected": "购买 · 请求被拒绝", "purchase-checking-result": "购买 · 正在核对结果", "startup-local-data-error": "启动 · 本地数据错误", "startup-automatic-open-unavailable": "启动 · 自动打开不可用",
    "reader-page-fit": "阅读器 · 单页适应屏幕", "reader-menu": "阅读器 · 插件菜单", "reader-next-free": "阅读器 · 下一章可直接阅读", "reader-next-locked": "阅读器 · 下一章待解锁", "reader-final-chapter": "阅读器 · 已到最后一章", "reader-long-strip": "阅读器 · 长条模式", "reader-zoom": "阅读器 · 放大阅读", "reader-image-loading": "阅读器 · 图片加载中",
    "reader-error-network": "阅读器 · 网络错误", "reader-error-auth": "阅读器 · 需要登录", "reader-error-low-space": "阅读器 · 存储空间不足", "reader-error-image-decode": "阅读器 · 图片解码失败", "reader-error-unsupported-image-size": "阅读器 · 图片尺寸不受支持", "reader-error-content-changed": "阅读器 · 内容已变化", "reader-error-version-replaced": "阅读器 · 阅读版本已替换", "reader-error-source-unavailable": "阅读器 · 图片源不可用",
    "generic-error-auth": "通用反馈 · 需要登录", "generic-error-network": "通用反馈 · 网络错误", "generic-error-low-space": "通用反馈 · 存储空间不足", "generic-error-capability": "通用反馈 · 能力不可用", "generic-error-locked": "通用反馈 · 章节未解锁", "generic-error-unsupported-image-size": "通用反馈 · 图片尺寸不受支持", "generic-error-in-use": "通用反馈 · 内容正在使用",
    "error-content-changed": "下载恢复 · 内容已变化", "error-unknown-history": "下载恢复 · 无法核对已有内容", "error-unverified-position": "下载恢复 · 阅读位置未核对", "error-reference-changed": "下载恢复 · 参考内容已变化", "error-stale-source-refresh": "下载恢复 · 刷新结果已过期", "error-source-refresh-interrupted": "下载恢复 · 图片源刷新中断", "error-chapter-active": "下载恢复 · 章节正在使用",
    "source-error-content-changed": "版本替换 · 内容已变化", "source-error-unknown-history": "版本替换 · 无法核对已有内容", "source-error-unverified-position": "版本替换 · 阅读位置未核对", "single-candidate": "购买 · 单章报价", "single-candidate-details": "购买 · 单章范围详情", "batch-candidate": "购买 · 批量报价", "batch-candidate-details": "购买 · 批量范围详情", "positive-ordinal-range": "购买 · 按序购买指定数量", "positive-ordinal-range-details": "购买 · 按序范围详情", "remaining-ordinal-range": "购买 · 从当前章购买剩余章节", "remaining-ordinal-range-details": "购买 · 剩余章节范围详情", "legacy-batch-without-proof": "购买 · 旧批量方案缺少范围依据", "legacy-batch-without-proof-details": "购买 · 旧批量方案范围详情",
}

PHRASES = {
    "unknown-history": "历史内容未知", "source-verification": "图片源核对", "bookstore-category-picker": "书城分类选择", "bookstore-categories": "书城分类", "bookstore-expanded": "书城", "bookshelf-finishing": "书架", "generic-error": "通用错误", "source-error": "图片源错误", "reader-error": "阅读器错误", "temporary-page": "临时权益章节页", "old-and-new": "新旧版本", "same-price": "价格未变化", "changed-price": "价格变化", "low-balance": "余额不足", "cached-offline": "离线有缓存", "uncached-offline": "离线无缓存", "uncached-error": "无缓存时加载失败", "cached-error": "有缓存时加载失败", "load-error": "加载失败", "retry-loaded": "重试成功", "first-page": "第一页", "last-page": "最后一页", "second-page": "第二页", "current-chapter": "当前章节", "no-record": "无阅读记录", "single-page": "单页内容", "server-end": "服务端无更多内容", "cache-limit": "缓存上限", "outcome-unknown": "结果未知", "outcome-pending": "结果待确认", "online-only": "仅在线", "not-found": "未找到", "rate-limit": "请求过于频繁", "file-picker": "文件选择", "remaining-range": "剩余范围", "free-only": "仅免费章节", "locked-only": "仅未解锁章节", "coupon-only": "仅使用券", "gold-only": "仅使用漫币", "no-selection": "尚未选择", "zero-price": "零价格", "invalid-session": "会话无效", "authentication-required": "需要登录", "right-to-left": "从右向左", "left-to-right": "从左向右",
}
TOKENS = {
    "bookshelf": "书架", "bookstore": "书城", "search": "搜索", "chapter": "章节", "chapters": "章节", "download": "下载", "downloads": "下载", "account": "账户", "purchase": "购买", "reader": "阅读器", "quote": "报价", "selection": "选择", "selected": "已选择", "details": "详情", "detail": "详情", "balance": "余额", "coupon": "券", "gold": "漫币", "single": "单章", "batch": "批量", "range": "范围", "page": "页", "loading": "加载中", "empty": "空状态", "loaded": "加载完成", "cached": "有缓存", "uncached": "无缓存", "offline": "离线", "online": "在线", "error": "错误", "failed": "失败", "failure": "失败", "confirmation": "确认", "confirmed": "已确认", "pending": "处理中", "unknown": "未知", "canceled": "已取消", "cancelled": "已取消", "complete": "已完成", "completed": "已完成", "queued": "排队中", "running": "运行中", "paused": "已暂停", "recovery": "恢复", "refresh": "刷新", "replacement": "版本替换", "source": "图片源", "sources": "图片源", "verification": "核对", "history": "历史", "price": "价格", "changed": "已变化", "unchanged": "未变化", "stale": "已过期", "expired": "已过期", "insufficient": "不足", "retry": "重试", "authentication": "身份验证", "authorization": "权限", "network": "网络", "timeout": "超时", "capability": "能力不可用", "unsupported": "不支持", "unavailable": "不可用", "protocol": "协议", "decrypt": "解密", "decryption": "解密", "decode": "解码", "invalid": "无效", "malformed": "格式错误", "response": "响应", "unexpected": "异常", "server": "服务端", "request": "请求", "payment": "支付", "payment-choice": "支付方式", "snapshot": "资产快照", "eligible": "可用", "ineligible": "不可用", "remaining": "剩余", "owned": "已拥有", "locked": "未解锁", "free": "免费", "mixed": "混合状态", "large": "大量内容", "many": "多项", "all": "全部", "none": "无", "zero": "零", "partial": "部分完成", "required": "需要", "minimum": "最少", "maximum": "最多", "min": "最少", "max": "最多", "total": "总计", "long": "长文本", "short": "短文本", "title": "标题", "titles": "标题", "valid": "有效", "successful": "成功", "success": "成功", "result": "结果", "results": "结果", "submission": "提交", "submitting": "正在提交", "rejected": "已拒绝", "terminal": "结束", "temporary": "临时权益", "ordinary": "普通权益", "entitlement": "权益", "display": "显示", "recommendations": "推荐", "synopsis": "简介", "filters": "筛选", "filter": "筛选", "picker": "选择器", "refreshed": "已刷新", "appended": "追加内容", "category": "分类", "categories": "分类", "help": "帮助", "more": "更多", "sort": "排序", "default": "默认", "legacy": "兼容入口", "entry": "入口", "after": "操作后", "hold": "长按", "new": "新版本", "old": "旧版本", "versions": "版本", "version": "版本", "queue": "队列", "prepare": "准备", "preparing": "准备中", "fetching": "获取中", "fetch": "获取", "continuation": "继续任务", "access": "阅读权限", "remove": "移除", "removed": "已移除", "refreshing": "刷新中", "input": "输入", "keyboard": "键盘", "session": "会话", "local": "本地", "diagnostics": "诊断", "storage": "存储", "disk": "磁盘", "space": "空间", "missing": "缺失", "corrupt": "损坏", "image": "图片", "images": "图片", "token": "令牌", "signature": "签名", "expired-token": "令牌过期", "limit": "限制", "exceeded": "超出", "disabled": "已禁用", "enabled": "已启用", "changed-source": "图片源变化", "canceled-by-user": "用户取消", "input-error": "输入错误", "id": "ID", "mc": "漫画", "comic": "漫画", "no": "无", "not": "未", "needs": "需要", "with": "含", "without": "无", "and": "与", "to": "至", "on": "开启", "off": "关闭", "first": "首次", "last": "最后", "next": "下一项", "previous": "上一项", "end": "结束", "overflow": "内容溢出", "sparse": "稀疏章节", "ordinal": "章节序号", "mismatch": "不一致", "mismatched": "不一致", "drift": "变化", "excluded": "已排除", "included": "已包含", "duplicate": "重复", "duplicates": "重复", "restricted": "受限制", "permission": "权限", "forbidden": "无权限", "authentication-expired": "登录已过期", "connectivity": "连接状态", "budget": "预算", "verification-needed": "需要核对", "unsupported-image": "不支持的图片", "cache": "缓存", "io": "读写", "api": "API", "http": "HTTP", "ttl": "有效期", "rental": "限时阅读", "rent": "限时阅读", "ticket": "券", "tickets": "券", "coupons": "券", "coin": "漫币", "coins": "漫币", "pending-list": "待确认记录", "chapters-left": "剩余章节", "full": "完整", "fee": "费用", "paid": "已付费", "resuming": "恢复中", "stopping": "停止中", "stopped": "已停止", "obsolete": "旧版本", "detached": "已分离", "unverified": "未核对", "verified": "已核对", "incomplete": "未完成", "refresh-required": "需要刷新", "size": "尺寸", "hash": "摘要", "checksum": "校验和", "encrypted": "已加密", "payment-disabled": "支付不可用",
}

MAIN_NAMES = {
    "bookshelf", "following", "bookshelf-finishing-default", "bookstore-expanded-recommendations", "bookstore-recommendations", "bookstore-categories-loaded", "bookstore-categories-homepage", "bookstore-homepage", "search", "chapters", "downloads", "account", "reader-page-fit", "reader-long-strip", "reader-zoom",
}
OVERVIEW_CANDIDATES = {
    "bookshelf": ["bookshelf-finishing-default", "native-bookshelf"],
    "bookstore": ["bookstore-categories-homepage", "bookstore-expanded-recommendations", "bookstore-categories-loaded", "bookstore-recommendations"],
    "search": ["native-search", "review-supplement-search-results"],
    "chapters": ["native-chapters"],
    "downloads": ["native-downloads"],
    "account": ["native-account"],
    "reader": ["review-reader-reader-page-fit", "review-reader-page-fit", "reader-page-fit"],
}


def normalized_name(name: str) -> str:
    name = name.replace("_", "-")
    for prefix in ("synthetic-review-", "synthetic-"):
        if name.startswith(prefix):
            return name[len(prefix):]
    return name


def slug(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")


def title_for(name: str, group: str) -> str:
    name = normalized_name(name)
    if name in OPTIMIZED_TITLES:
        return OPTIMIZED_TITLES[name]
    if name in TITLES:
        return TITLES[name]
    pieces = name.split("-")
    translated = []
    index = 0
    phrases = {**TOKENS, **PHRASES}
    while index < len(pieces):
        matched = False
        for size in range(min(5, len(pieces) - index), 0, -1):
            phrase = "-".join(pieces[index:index + size])
            if phrase in phrases:
                translated.append(phrases[phrase])
                index += size
                matched = True
                break
        if not matched:
            if pieces[index].isdigit():
                translated.append(pieces[index])
            index += 1
    if translated:
        return " · ".join(dict.fromkeys(translated))
    return next(item["title"] for item in GROUPS if item["id"] == group) + " · 其他状态"


def group_for(suite: str, name: str) -> str:
    name = normalized_name(name)
    if name.startswith(("chapter-", "comic-overview", "cross-page-download-selection")):
        return "chapters"
    if name in {"expired-quote", "pending-result-network-recovery"}:
        return "purchase"
    if name == "empty-search":
        return "search"
    if name == "empty-downloads":
        return "downloads"
    # Explicit screen names take precedence over broad native and supplement suites.
    if name.startswith("reader-") or suite in {"reader", "review-reader"}:
        return "reader"
    if name.startswith(("search", "comic-id")):
        return "search"
    if name in {"chapters", "follow-pending", "download-selection"} or name.startswith("chapters-") or name.endswith("-chapters") or "entitlement" in suite:
        return "chapters"
    if name.startswith(("purchase", "quote", "coupon", "pending-purchase")) or name == "locked-download-action" or suite in {"quote-selection", "ordinal-range"}:
        return "purchase"
    if name.startswith(("download", "failed-download", "paused-download", "canceled-download", "removed-download")) or suite in {"download-recovery", "version-replacement"}:
        return "downloads"
    if name.startswith(("bookstore", "recommendation")):
        return "bookstore"
    if name.startswith(("bookshelf", "following", "empty-bookshelf", "legacy-history")):
        return "bookshelf"
    if name.startswith(("account", "session", "qr-", "local-diagnostic", "diagnostics", "cache-clear", "generic-error", "startup")):
        return "account"
    if "bookstore" in suite:
        return "bookstore"
    if "bookshelf" in suite:
        return "bookshelf"
    if any(token in suite for token in ("account", "session", "login")):
        return "account"
    return "account"


def read_json(path: Path) -> dict:
    if not path.is_file():
        return {}
    value = json.loads(path.read_text(encoding="utf-8"))
    return value if isinstance(value, dict) else {}


def capture_metadata(captures: Path) -> tuple[dict, dict]:
    manifest = read_json(captures / "review-capture-manifest.json")
    summary = read_json(captures / "capture-summary.json")
    metadata = {}
    for source in (manifest, summary):
        records = source.get("screenshots", [])
        if not isinstance(records, list):
            continue
        for record in records:
            if isinstance(record, dict) and isinstance(record.get("path"), str):
                metadata[record["path"].replace("\\", "/")] = record
    provenance = {
        "captureMethod": "KOReader native framebuffer",
        "syntheticData": True,
        "environment": summary.get("environment", manifest.get("environment", "ssh test-env")),
        "runtimeVersion": summary.get("runtime_version", manifest.get("runtime_version")),
        "revision": summary.get("revision", summary.get("commit", summary.get("base_commit", manifest.get("revision", manifest.get("base_commit"))))),
        "captureStartedAt": summary.get("started_at", summary.get("captured_at", manifest.get("started_at", manifest.get("captured_at")))),
        "captureFinishedAt": summary.get("finished_at", summary.get("captured_at", manifest.get("finished_at", manifest.get("captured_at")))),
        "captureChecksPassed": manifest.get("passed"),
        "sourceUnchanged": manifest.get("source_unchanged"),
        "notes": "Native screens with synthetic fixtures; screenshot coverage does not establish live service behavior.",
    }
    return metadata, provenance


def capture_identity(relative: Path, record: dict) -> tuple[str, str]:
    parts = list(relative.parts[:-1])
    if parts and parts[0] in {"suites", "output"}:
        parts.pop(0)
    suite = str(record.get("suite") or (parts[0] if parts else "native"))
    suite = re.sub(r"-\d{3,4}x\d{3,4}$", "", suite)
    language = record.get("language")
    # Locale directory names are authoritative, including C as English.
    for part in parts:
        match = DIMENSIONS.fullmatch(part)
        if match and match.group(1):
            language = match.group(1)
        elif part in {"zh_CN", "zh-CN", "C", "en", "en_US"}:
            language = part
    if language is None:
        language = "zh_CN" if suite in CHINESE_SUITES else "en"
    locale = "zh_CN" if language in {"zh_CN", "zh-CN"} else "en"
    return slug(suite), locale


def excluded_image(relative: Path) -> bool:
    return relative.name == "oversized-cover.png" or any(
        part in IGNORED_DIRECTORIES or part.startswith(("xdg_", "xdg-"))
        for part in relative.parts[:-1]
    )


def preferred_variant(screen: dict) -> dict:
    priorities = [("zh_CN", "600x800"), ("en", "600x800"), ("zh_CN", "480x640"), ("en", "480x640")]
    for locale, resolution in priorities:
        for variant in screen["variants"]:
            if variant["locale"] == locale and variant["resolution"] == resolution:
                return variant
    return screen["variants"][0]


def select_overview(screens: list[dict]) -> list[str]:
    by_id = {screen["id"]: screen for screen in screens}
    selected = []
    for group, candidates in OVERVIEW_CANDIDATES.items():
        screen = next((by_id[candidate] for candidate in candidates if candidate in by_id), None)
        if screen is None:
            screen = next((item for item in screens if item["group"] == group and item["kind"] == "main"), None)
        if screen is not None:
            selected.append(screen["id"])
    return selected


def load_font(size: int, font_path: Path | None = None):
    if font_path is not None:
        if not font_path.is_file():
            raise ValueError("The supplied UI review font does not exist: " + str(font_path))
        return ImageFont.truetype(str(font_path), size)
    for path in (
        "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc",
        "C:/Windows/Fonts/msyh.ttc",
        "C:/Windows/Fonts/simsun.ttc",
    ):
        if Path(path).is_file():
            return ImageFont.truetype(path, size)
    raise ValueError("A CJK font is required for Chinese contact sheets. Set UI_REVIEW_FONT or pass --font.")


def fit_caption(draw, value: str, font, width: int) -> str:
    if draw.textbbox((0, 0), value, font=font)[2] <= width:
        return value
    while value and draw.textbbox((0, 0), value + "…", font=font)[2] > width:
        value = value[:-1]
    return value + "…"


def contact_sheet(screens: list[dict], output: Path, filename: str, title: str, font_path: Path | None = None) -> dict:
    if not screens:
        return {}
    columns = min(4 if len(screens) > 6 else 3, len(screens))
    tile_width, image_height, caption_height = 280, 365, 70
    gap, margin, header = 22, 30, 92
    rows = math.ceil(len(screens) / columns)
    width = margin * 2 + columns * tile_width + (columns - 1) * gap
    height = header + rows * (image_height + caption_height + gap) + margin - gap
    canvas = Image.new("RGB", (width, height), "#e9eef3")
    draw = ImageDraw.Draw(canvas)
    title_font, body_font, label_font = load_font(25, font_path), load_font(13, font_path), load_font(10, font_path)
    draw.text((margin, 20), fit_caption(draw, title, title_font, width - margin * 2), font=title_font, fill="#152436")
    subtitle = fit_caption(draw, "KOReader 原生界面 · 合成测试数据 · 完整原图与批注入口见图集", body_font, width - margin * 2)
    draw.text((margin, 58), subtitle, font=body_font, fill="#546477")
    cells = []
    for index, screen in enumerate(screens):
        variant = preferred_variant(screen)
        left = margin + (index % columns) * (tile_width + gap)
        top = header + (index // columns) * (image_height + caption_height + gap)
        draw.rounded_rectangle((left, top, left + tile_width, top + image_height), radius=4, fill="#d8e0e8", outline="#becbd8")
        with Image.open(output / variant["src"]) as original:
            thumbnail = ImageOps.contain(original.convert("RGB"), (tile_width - 22, image_height - 24), Image.Resampling.LANCZOS)
        canvas.paste(thumbnail, (left + (tile_width - thumbnail.width) // 2, top + (image_height - thumbnail.height) // 2))
        caption = fit_caption(draw, f'{screen["number"]:03d}  {screen["title"]}', body_font, tile_width)
        draw.text((left, top + image_height + 8), caption, font=body_font, fill="#152436")
        identifier = fit_caption(draw, screen["id"], label_font, tile_width)
        draw.text((left, top + image_height + 30), identifier, font=label_font, fill="#546477")
        locale = "简体中文" if variant["locale"] == "zh_CN" else "英文界面"
        draw.text((left, top + image_height + 49), f'{locale} · {variant["width"]} × {variant["height"]}', font=label_font, fill="#546477")
        cells.append({"screenId": screen["id"], "variant": variant["src"]})
    canvas.save(output / filename, optimize=True)
    return {"src": filename, "width": width, "height": height, "screens": cells}


def build(captures: Path, output: Path, font_path: Path | None = None) -> dict:
    captures, output = captures.resolve(), output.resolve()
    if font_path is None and os.environ.get("UI_REVIEW_FONT"):
        font_path = Path(os.environ["UI_REVIEW_FONT"])
    if not captures.is_dir():
        raise ValueError("The capture directory does not exist.")
    if captures == output or captures in output.parents:
        raise ValueError("The output must be outside the capture tree to avoid recursive image collection.")
    metadata, provenance = capture_metadata(captures)
    source_paths = [path for path in sorted(captures.rglob("*.png")) if not excluded_image(path.relative_to(captures))]
    output.mkdir(parents=True, exist_ok=True)
    records = {}
    capture_count = 0
    for path in source_paths:
        relative = path.relative_to(captures)
        record = metadata.get(relative.as_posix(), {})
        suite, locale = capture_identity(relative, record)
        name = normalized_name(path.stem)
        screen_id = slug(name if name.startswith(suite + "-") else suite + "-" + name)
        group = group_for(suite, name)
        destination = output / "screens" / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, destination)
        with Image.open(path) as image:
            width, height = image.size
        resolution = f"{width}x{height}"
        variant = {
            "locale": locale, "resolution": resolution, "width": width, "height": height,
            "src": destination.relative_to(output).as_posix(), "capturePath": relative.as_posix(),
            "sha256": record.get("sha256") or hashlib.sha256(path.read_bytes()).hexdigest(),
        }
        if screen_id not in records:
            records[screen_id] = {
                "id": screen_id, "title": title_for(name, group), "filename": path.name,
                "suite": suite, "group": group, "kind": "main" if name in MAIN_NAMES else "state",
                "syntheticData": True, "captureMethod": "KOReader native framebuffer", "variants": [],
            }
        existing = records[screen_id]
        duplicate = next((item for item in existing["variants"] if item["locale"] == locale and item["resolution"] == resolution), None)
        if duplicate:
            # Preserve repeated captures as separate scenes instead of silently dropping an original.
            screen_id += "-" + hashlib.sha256(relative.as_posix().encode()).hexdigest()[:8]
            records[screen_id] = {**existing, "id": screen_id, "variants": [variant]}
        else:
            existing["variants"].append(variant)
        capture_count += 1
    if not records:
        raise ValueError("No screenshot PNG files were found outside fixture directories.")
    screens = sorted(records.values(), key=lambda item: (GROUP_ORDER[item["group"]], item["kind"] != "main", item["id"]))
    for index, screen in enumerate(screens, 1):
        screen["number"] = index
        screen["variants"].sort(key=lambda item: (item["locale"] != "zh_CN", item["resolution"] != "600x800", item["width"], item["height"]))
    overview_ids = select_overview(screens)
    manifest = {
        "schemaVersion": 1, "generatedAt": datetime.now(timezone.utc).isoformat(),
        "captureCount": capture_count, "sceneCount": len(screens), "groups": GROUPS,
        "overviewIds": overview_ids, "provenance": provenance, "screens": screens, "contactSheets": [],
    }
    by_id = {screen["id"]: screen for screen in screens}
    overview = contact_sheet([by_id[screen_id] for screen_id in overview_ids], output, "overview.png", "书架 · 单行工具栏与紧凑网格", font_path)
    if overview:
        manifest["contactSheets"].append(overview)
    for group in GROUPS:
        members = [screen for screen in screens if screen["group"] == group["id"]]
        pages = math.ceil(len(members) / 20)
        for page in range(pages):
            suffix = f"-{page + 1:02d}" if pages > 1 else ""
            filename = f'group-{group["id"]}{suffix}.png'
            title = "BiliComics · " + group["title"] + (f" · 第 {page + 1} / {pages} 张" if pages > 1 else "")
            sheet = contact_sheet(members[page * 20:(page + 1) * 20], output, filename, title, font_path)
            sheet["group"] = group["id"]
            manifest["contactSheets"].append(sheet)
    payload = json.dumps(manifest, ensure_ascii=False, indent=2)
    (output / "manifest.json").write_text(payload + "\n", encoding="utf-8")
    (output / "data.js").write_text("window.UI_REVIEW_DATA = " + payload + ";\n", encoding="utf-8")
    source = Path(__file__).resolve().parent
    for name in ("index.html", "styles.css", "app.js", "README.md", "build_gallery.py"):
        if (source / name).resolve() != (output / name).resolve():
            shutil.copy2(source / name, output / name)
    for name in ("review-capture-manifest.json", "capture-summary.json"):
        if (captures / name).is_file():
            shutil.copy2(captures / name, output / name)
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--captures", type=Path, required=True, help="The root containing screenshot suites and optional capture metadata.")
    parser.add_argument("--output", type=Path, required=True, help="A self-contained gallery directory outside the capture tree.")
    parser.add_argument("--font", type=Path, help="A CJK font for contact sheets; defaults to UI_REVIEW_FONT or an installed CJK font.")
    args = parser.parse_args()
    manifest = build(args.captures, args.output, args.font)
    print(json.dumps({"scene_count": manifest["sceneCount"], "capture_count": manifest["captureCount"], "contact_sheet_count": len(manifest["contactSheets"]), "output": str(args.output.resolve())}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
