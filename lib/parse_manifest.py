#!/usr/bin/env python3
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def parse_manifest(manifest_path):
    root = ET.parse(manifest_path).getroot()
    default_rev = ""
    default_el = root.find("default")
    if default_el is not None:
        default_rev = default_el.get("revision", "")

    projects = []
    for proj in root.findall("project"):
        name = proj.get("name", "")
        path = proj.get("path", name)
        revision = proj.get("revision", default_rev)
        projects.append({"name": name, "path": path, "revision": revision})
    return projects


def resolve_manifest_entry(repo_dir):
    manifest_xml = Path(repo_dir) / ".repo" / "manifest.xml"
    if not manifest_xml.exists():
        raise FileNotFoundError(f"missing manifest: {manifest_xml}")

    root = ET.parse(manifest_xml).getroot()
    include = root.find("include")
    if include is not None:
        rel = include.get("name", "")
        resolved = Path(repo_dir) / ".repo" / "manifests" / rel
        if resolved.exists():
            return resolved
    return manifest_xml


def load_sync_rules(rules_path):
    rules = []
    with open(rules_path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split(":")
            if len(parts) != 3:
                raise ValueError(f"invalid rule (need gerrit:github:flag): {line}")
            gerrit_path, github_path, flag = parts
            if flag not in ("0", "1"):
                raise ValueError(f"invalid subdir flag in rule: {line}")
            rules.append(
                {
                    "gerrit_path": gerrit_path,
                    "github_path": github_path,
                    "merge_flag": flag,
                }
            )
    return rules


def child_rule_paths(parent_path, rules):
    prefix = parent_path + "/"
    children = []
    for rule in rules:
        gh_path = rule["github_path"]
        if gh_path.startswith(prefix):
            children.append(gh_path)
    return sorted(children)


def build_sync_plan_from_rules(gerrit_dir, github_dir, rules_path):
    gerrit_manifest = resolve_manifest_entry(gerrit_dir)
    github_manifest = resolve_manifest_entry(github_dir)

    gerrit_projects = parse_manifest(gerrit_manifest)
    github_projects = parse_manifest(github_manifest)

    gerrit_by_path = {p["path"]: p for p in gerrit_projects}
    github_by_path = {p["path"]: p for p in github_projects}

    rules = load_sync_rules(rules_path)
    plan = []

    for rule in rules:
        gh_path = rule["github_path"]
        gr_path = rule["gerrit_path"]
        merge_flag = rule["merge_flag"]

        gh = github_by_path.get(gh_path)
        gh_name = gh["name"] if gh else ""
        gh_rev = gh["revision"] if gh else ""

        gr = gerrit_by_path.get(gr_path)
        if gr is None:
            plan.append(
                {
                    "github_path": gh_path,
                    "github_name": gh_name,
                    "github_revision": gh_rev,
                    "gerrit_path": gr_path,
                    "gerrit_name": "",
                    "gerrit_revision": "",
                    "status": "no_gerrit",
                    "exclude_subpaths": [],
                    "merge_flag": merge_flag,
                }
            )
            continue

        excludes = child_rule_paths(gh_path, rules)
        plan.append(
            {
                "github_path": gh_path,
                "github_name": gh_name,
                "github_revision": gh_rev,
                "gerrit_path": gr["path"],
                "gerrit_name": gr["name"],
                "gerrit_revision": gr["revision"],
                "status": "sync",
                "exclude_subpaths": excludes,
                "merge_flag": merge_flag,
            }
        )

    plan.sort(key=lambda x: x["github_path"].count("/"), reverse=True)
    return plan, str(gerrit_manifest), str(github_manifest)


def main():
    if len(sys.argv) != 4:
        print(
            "usage: parse_manifest.py <gerrit_dir> <github_dir> <rules_file>",
            file=sys.stderr,
        )
        sys.exit(1)

    plan, gerrit_mf, github_mf = build_sync_plan_from_rules(
        sys.argv[1], sys.argv[2], sys.argv[3]
    )
    print(f"GERRIT_MANIFEST={gerrit_mf}")
    print(f"GITHUB_MANIFEST={github_mf}")
    for item in plan:

        def field(value):
            return value if value else "-"

        excludes = ",".join(item["exclude_subpaths"])
        fields = [
            field(item["status"]),
            field(item["github_path"]),
            field(item["gerrit_path"]),
            field(item["gerrit_name"]),
            field(item["gerrit_revision"]),
            field(item["github_name"]),
            field(item["github_revision"]),
            field(excludes),
            field(item["merge_flag"]),
        ]
        print("|".join(fields))


if __name__ == "__main__":
    main()
