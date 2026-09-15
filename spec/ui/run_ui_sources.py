"""List the complete UI source surface for isolated native verification reports."""
from pathlib import Path


def ui_source_names(plugin):
    plugin = Path(plugin)
    sources = [path.relative_to(plugin).as_posix() for path in (plugin / "bilicomics/ui").glob("*.lua")]
    sources.extend(path.relative_to(plugin).as_posix() for path in (plugin / "l10n").glob("bilicomics*_zh_CN.lua"))
    if (plugin / "main.lua").is_file():
        sources.append("main.lua")
    return tuple(sorted(set(sources)))
