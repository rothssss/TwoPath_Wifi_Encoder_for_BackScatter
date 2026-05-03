#!/usr/bin/env python3
"""Port of gen_single_module_flat.ps1 for hosts without PowerShell.

Reads `multi_mode_tx_baseband_flat_multimodule.v` (a concatenation of every
module the design needs, in dependency order) and emits a single-module
flattened top-level by inlining each instance, prefixing locals so they do
not collide.  Output mirrors the PowerShell script's conventions:
  * top-of-tree functions hoisted out of `always` bodies and placed first;
  * a hand-curated wire->reg coercion list for the named Path-A wires that
    end up driven inside an inlined `always` block.
"""
from __future__ import annotations

import argparse
import re
from pathlib import Path

WORD_BOUNDARY_TEMPLATE = r"(?<![A-Za-z0-9_$.]){0}(?![A-Za-z0-9_$])"


def replace_word(text: str, name: str, replacement: str) -> str:
    pattern = WORD_BOUNDARY_TEMPLATE.format(re.escape(name))
    return re.sub(pattern, lambda m: replacement, text)


def parse_param_block(text: str) -> "dict[str, str]":
    out: "dict[str, str]" = {}
    if not text or not text.strip():
        return out
    pattern = re.compile(
        r"parameter\b(?:\s+integer\b)?(?:\s*\[[^\]]+\])?\s+([A-Za-z_][A-Za-z0-9_$]*)\s*=\s*([^,\r\n]+)"
    )
    for m in pattern.finditer(text):
        out[m.group(1)] = m.group(2).strip()
    return out


def parse_port_names(text: str) -> "list[str]":
    names: "list[str]" = []
    if not text or not text.strip():
        return names
    pattern = re.compile(
        r"(?m)^\s*(?:input|output|inout)\b[^;\n]*?\b([A-Za-z_][A-Za-z0-9_$]*)\b(?=\s*(?:,|//|$))"
    )
    for m in pattern.finditer(text):
        n = m.group(1)
        if n not in names:
            names.append(n)
    return names


def parse_declared_names(body: str) -> "list[str]":
    names: "list[str]" = []

    def _add(n: str) -> None:
        if n and n not in names:
            names.append(n)

    for m in re.finditer(r"(?ms)^\s*localparam\b(.*?);", body):
        for n in re.finditer(r"([A-Za-z_][A-Za-z0-9_$]*)\s*=", m.group(1)):
            _add(n.group(1))

    decl_re = re.compile(
        r"(?ms)^\s*(?:reg|wire|integer)\b(?:\s+(?:signed|unsigned))?(?:\s*\[[^\]]+\])?\s*(.*?);"
    )
    for m in decl_re.finditer(body):
        decl_text = m.group(1)
        if "=" in decl_text:
            head = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_$]*)\b", decl_text)
            if head:
                _add(head.group(1))
        else:
            for part in decl_text.split(","):
                head = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_$]*)\b", part)
                if head:
                    _add(head.group(1))

    for m in re.finditer(
        r"(?m)^\s*function\b(?:\s+\[[^\]]+\])?\s*([A-Za-z_][A-Za-z0-9_$]*)\s*;",
        body,
    ):
        _add(m.group(1))

    return names


def parse_named_args(text: str) -> "dict[str, str]":
    out: "dict[str, str]" = {}
    if not text or not text.strip():
        return out
    pattern = re.compile(
        r"(?ms)\.([A-Za-z_][A-Za-z0-9_$]*)\s*\(\s*(.*?)\s*\)\s*(?:,|$)"
    )
    for m in pattern.finditer(text):
        out[m.group(1)] = m.group(2).strip()
    return out


def parse_modules(source: str) -> "dict[str, dict]":
    pattern = re.compile(
        r"(?ms)module\s+([A-Za-z_][A-Za-z0-9_$]*)\s*(?:#\((.*?)\))?\s*\((.*?)\);\s*(.*?)\s*endmodule"
    )
    modules: "dict[str, dict]" = {}
    for m in pattern.finditer(source):
        name = m.group(1)
        param_text = (m.group(2) or "").strip()
        port_text = (m.group(3) or "").strip()
        body = (m.group(4) or "").strip()
        modules[name] = {
            "name": name,
            "param_text": param_text,
            "port_text": port_text,
            "body": body,
            "param_defaults": parse_param_block(m.group(2) or ""),
            "ports": parse_port_names(m.group(3) or ""),
        }
    return modules


def convert_module(
    modules: "dict[str, dict]",
    module_name: str,
    prefix: str,
    param_map: "dict[str, str]",
    conn_map: "dict[str, str]",
    top_module: str,
) -> str:
    mod = modules[module_name]
    body = mod["body"]

    locals_ = [
        n
        for n in parse_declared_names(body)
        if n not in mod["param_defaults"] and n not in mod["ports"]
    ]
    for name in locals_:
        body = replace_word(body, name, f"{prefix}__{name}")

    for pname, default in mod["param_defaults"].items():
        value = param_map.get(pname, default)
        body = replace_word(body, pname, value)

    for port in mod["ports"]:
        if port in conn_map:
            body = replace_word(body, port, conn_map[port])

    body = inline_instances(modules, body, prefix, top_module)
    return (
        "// ---------------------------------------------------------------------------\n"
        f"// Inlined {module_name} instance: {prefix}\n"
        "// ---------------------------------------------------------------------------\n"
        f"{body}\n"
    )


def inline_instances(
    modules: "dict[str, dict]",
    body: str,
    prefix: str,
    top_module: str,
) -> str:
    child_names = [n for n in modules.keys() if n != top_module]
    if not child_names:
        return body
    alt = "|".join(re.escape(n) for n in child_names)
    inst_re = re.compile(
        r"(?ms)^\s*(?P<mod>" + alt + r")\s*(?:#\((?P<params>.*?)\))?\s*"
        r"(?P<inst>[A-Za-z_][A-Za-z0-9_$]*)\s*\((?P<conns>.*?)\)\s*;\s*$"
    )

    while True:
        m = inst_re.search(body)
        if not m:
            break
        child_name = m.group("mod")
        child_inst = m.group("inst")
        child_prefix = f"{prefix}__{child_inst}"

        param_map = dict(modules[child_name]["param_defaults"])
        param_overrides = parse_named_args(m.group("params") or "")
        for k, v in param_overrides.items():
            param_map[k] = v

        conn_map = parse_named_args(m.group("conns") or "")
        inlined = convert_module(
            modules, child_name, child_prefix, param_map, conn_map, top_module
        )
        body = body[: m.start()] + inlined + body[m.end():]
    return body


WIRE_TO_REG_REPLACEMENTS = [
    (re.compile(r"(?m)^\s*wire\s+a_fifo_rd_en\s*;\s*$"),         "    reg         a_fifo_rd_en;"),
    (re.compile(r"(?m)^\s*wire\s+a_busy\s*;\s*$"),               "    reg         a_busy;"),
    (re.compile(r"(?m)^\s*wire\s+a_done\s*;\s*$"),               "    reg         a_done;"),
    (re.compile(r"(?m)^\s*wire\s+a_underrun\s*;\s*$"),           "    reg         a_underrun;"),
    (re.compile(r"(?m)^\s*wire\s+\[1:0\]\s+a_base_phase\s*;\s*$"), "    reg  [1:0]  a_base_phase;"),
    (re.compile(r"(?m)^\s*wire\s+\[1:0\]\s+a_delta_phi1\s*;\s*$"), "    reg  [1:0]  a_delta_phi1;"),
    (re.compile(r"(?m)^\s*wire\s+a_update_phi1\s*;\s*$"),        "    reg         a_update_phi1;"),
    (re.compile(r"(?m)^\s*wire\s+a_chip_valid_to_phy\s*;\s*$"),  "    reg         a_chip_valid_to_phy;"),
    (re.compile(r"(?m)^\s*wire\s+a_chip_i\s*;\s*$"),             "    reg         a_chip_i;"),
    (re.compile(r"(?m)^\s*wire\s+a_chip_q\s*;\s*$"),             "    reg         a_chip_q;"),
    (re.compile(r"(?m)^\s*wire\s+a_chip_valid_out\s*;\s*$"),     "    reg         a_chip_valid_out;"),
]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--source",
        default="synth/rtl_flat/multi_mode_tx_baseband_flat_multimodule.v",
    )
    ap.add_argument(
        "--output",
        default="synth/rtl_flat/multi_mode_tx_baseband_flat.v",
    )
    ap.add_argument("--top", default="multi_mode_tx_baseband")
    args = ap.parse_args()

    src = Path(args.source).read_text()
    timescale_match = re.search(r"(?m)^`timescale\s+[^\r\n]+", src)
    timescale = timescale_match.group(0) if timescale_match else "`timescale 1ns/1ps"

    modules = parse_modules(src)
    if args.top not in modules:
        raise SystemExit(f"Top module {args.top!r} not found in {args.source}")

    top = modules[args.top]
    body = inline_instances(modules, top["body"], args.top, args.top)

    leftover_alt = "|".join(
        re.escape(n) for n in modules.keys() if n != args.top
    )
    if leftover_alt:
        if re.search(r"(?m)^\s*(?:" + leftover_alt + r")\b", body):
            raise SystemExit("Flattening incomplete: leftover module instantiations remain.")

    for pat, repl in WIRE_TO_REG_REPLACEMENTS:
        body = pat.sub(repl, body)

    func_re = re.compile(r"(?ms)^\s*function\b.*?^\s*endfunction\s*")
    funcs = [m.group(0).rstrip() for m in func_re.finditer(body)]
    body = func_re.sub("", body)
    function_section = ""
    if funcs:
        function_section = "\n\n".join(funcs) + "\n\n"

    param_block = ""
    if top["param_text"].strip():
        param_block = f"#(\n{top['param_text']}\n) "

    header = (
        "// =============================================================================\n"
        "// multi_mode_tx_baseband_flat.v\n"
        "//\n"
        "// Single-module flattened top-level RTL for synthesis handoff / export.\n"
        "// The helper instances from the original hierarchical design are inlined into\n"
        "// the top module below. The hierarchical multi-module stitch-up is preserved in\n"
        "// multi_mode_tx_baseband_flat_multimodule.v for module-level benches.\n"
        "// =============================================================================\n"
        f"{timescale}\n\n"
        f"module {args.top} {param_block}(\n"
        f"{top['port_text']}\n"
        ");\n\n"
        f"{function_section}"
    )

    out = header + body.strip() + "\n\nendmodule\n"
    Path(args.output).write_text(out)


if __name__ == "__main__":
    main()
