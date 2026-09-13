"""Compare actual official reader.lua cold startup with normal plugin and late hook."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


def literal(value):
    return json.dumps(str(value))


def main():
    if sys.platform != "linux":
        raise RuntimeError("Run only on the authorized remote verification host")
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--plugin", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    args = parser.parse_args()
    summary = []
    for mode in ("plugin-init", "plugin-top-level", "late-hook"):
        root = args.output / mode
        home = root / "data"
        patches = home / "patches"
        plugin_dir = home / "plugins" / "startup-probe.koplugin"
        patches.mkdir(parents=True, exist_ok=True)
        plugin_dir.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(args.fixture, root / "page.png")
        descriptor = {"schema_version": 1, "account_key": "test", "comic_id": "comic",
                      "episode_id": "episode", "revision": "r1",
                      "pages": [{"id": "page", "index": 1, "width": 600, "height": 2400}]}
        (root / "chapter.bcomic").write_text(json.dumps(descriptor))
        disabled = ",".join(f"[{literal(path.name[:-9])}]=true" for path in (args.runtime / "plugins").glob("*.koplugin"))
        (home / "settings.reader.lua").write_text("return {"
            f"start_with='last',lastfile={literal(root / 'chapter.bcomic')},"
            "quickstart_shown_version=9999999999,color_rendering=false,"
            f"plugins_disabled={{{disabled}}},extra_plugin_paths={{{literal(home / 'plugins')}}},"
            f"home_dir={literal(root)}}}")
        # This fixture bootstrap is shared by the normal plugin and optional real late hook.
        # The observer above does not load it. Every invocation comes from official app loading.
        (plugin_dir / "startup_bootstrap.lua").write_text(f"""
local Provider = require('bilicomics/reader/document')
local function bootstrap()
    _G.bilicomics_startup_bootstrap = true
    Provider:setServicesResolver(function()
        return {{ authorizeDescriptor = function() return true end, pages = {{ getPage = function()
            return {{ id='page',index=1,episode_id='episode',revision='r1',state='ready',
                path={literal(root / 'page.png')},width=600,height=2400,format='png',
                content_generation=1,geometry_generation=1 }}
        end }}, store = {{ getEpisode=function() return {{title='Startup fixture'}} end,
            getComic=function() return {{title='Startup fixture'}} end }}, settings = {{}} }}
    end)
    Provider:register()
end
return bootstrap
""")
        top = "bootstrap()" if mode == "plugin-top-level" else ""
        (plugin_dir / "main.lua").write_text(f"""
package.path = {literal(args.plugin / '?.lua')} .. ';' .. package.path
local bootstrap = require('startup_bootstrap')
{top}
local Plugin = require('ui/widget/container/widgetcontainer'):extend{{}}
function Plugin:init()
    _G.bilicomics_startup_plugin_init = true
    bootstrap()
end
return Plugin
""")
        (plugin_dir / "_meta.lua").write_text("return {fullname='Startup probe',description='Isolated startup contract fixture'}")
        shutil.copyfile(args.plugin / "spec/reader/startup_probe.lua", patches / "2-00-observe.lua")
        if mode == "late-hook":
            (patches / "2-10-startup-provider.lua").write_text(
                f"package.path={literal(plugin_dir / '?.lua')}..';'..{literal(args.plugin / '?.lua')}..';'..package.path\n"
                "require('startup_bootstrap')()\n")
        env = os.environ.copy()
        env.update(KO_HOME=str(home), BILICOMICS_STARTUP_PROBE_ROOT=str(root),
                   EMULATE_READER_W="600", EMULATE_READER_H="800", SDL_AUDIODRIVER="dummy")
        process = subprocess.run(["xvfb-run", "-a", str(args.runtime / "luajit"), "reader.lua"],
                                 cwd=args.runtime, env=env, text=True, capture_output=True, timeout=20)
        (root / "startup.log").write_text(process.stdout + process.stderr)
        result_file = root / "startup-results.json"
        report = json.loads(result_file.read_text()) if result_file.exists() else {}
        expected = mode == "late-hook"
        passed = bool(report and report.get("reader_opened") == expected
                      and report.get("first_show", {}).get("provider_available") == expected
                      and not report.get("plugins_loaded_at_late_patch"))
        summary.append({"mode": mode, "returncode": process.returncode, "passed": passed, "report": report})
        print(json.dumps(summary[-1]), flush=True)
        if not passed:
            print((process.stdout + process.stderr)[-5000:])
    (args.output / "startup-results.json").write_text(json.dumps(summary, indent=2) + "\n")
    return int(not all(item["passed"] for item in summary))


if __name__ == "__main__":
    raise SystemExit(main())
