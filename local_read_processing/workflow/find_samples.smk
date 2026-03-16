"""
File-discovery workflow.

Scans /mnt/hpccs01/datasets/deepocean for FASTQ files, skipping any
directory whose name ends with '_qc'.  Handles both flat layouts:
  <dir>/<ACC>_1.fastq.gz
and one-level-nested layouts:
  <dir>/<ACC>/<ACC>_1.fastq.gz

Produces config/samples.csv with columns: acc, r1, r2
(r2 is empty for single-end samples).
"""

import os
import re
from collections import defaultdict
from pathlib import Path

DEEPOCEAN_DIR = "/mnt/hpccs01/datasets/deepocean"
SAMPLES_CSV   = "config/samples.csv"

# Load blacklisted sample accessions from all files in blacklists/
BLACKLIST = set()
for _bl_file in Path("blacklists").glob("*"):
    if _bl_file.is_file():
        BLACKLIST.update(
            line.strip()
            for line in _bl_file.read_text().splitlines()
            if line.strip() and not line.startswith("#")
        )


rule all:
    input: SAMPLES_CSV


rule find_samples:
    output: SAMPLES_CSV
    run:
        deepocean = Path(DEEPOCEAN_DIR)
        samples = defaultdict(dict)   # acc -> {r1, r2}

        def process_fastq(f):
            name = f.name
            # paired forward
            m = re.fullmatch(r"(.+)_1\.fastq\.gz", name)
            if m:
                acc = m.group(1)
                samples[acc].setdefault("r1", str(f))
                return
            # paired reverse
            m = re.fullmatch(r"(.+)_2\.fastq\.gz", name)
            if m:
                acc = m.group(1)
                samples[acc]["r2"] = str(f)
                return
            # single-end (no _1 / _2 suffix)
            m = re.fullmatch(r"(.+)\.fastq\.gz", name)
            if m:
                acc = m.group(1)
                # Don't clobber a paired _1 already registered
                if "r1" not in samples[acc]:
                    samples[acc]["r1"] = str(f)

        for top in sorted(deepocean.iterdir()):
            if not top.is_dir():
                continue
            if top.name.endswith("_qc"):
                continue

            # Flat: files directly inside top-level dir
            for f in sorted(top.glob("*.fastq.gz")):
                process_fastq(f)

            # Nested: one sub-directory per accession
            for sub in sorted(top.iterdir()):
                if not sub.is_dir():
                    continue
                for f in sorted(sub.glob("*.fastq.gz")):
                    process_fastq(f)

        kept = {acc: v for acc, v in samples.items() if acc not in BLACKLIST}

        os.makedirs("config", exist_ok=True)
        with open(output[0], "w") as fh:
            fh.write("acc,r1,r2\n")
            for acc in sorted(kept):
                r1 = kept[acc].get("r1", "")
                r2 = kept[acc].get("r2", "")
                fh.write(f"{acc},{r1},{r2}\n")

        n_paired = sum(1 for v in kept.values() if v.get("r2"))
        n_single = sum(1 for v in kept.values() if not v.get("r2"))
        n_blacklisted = len(samples) - len(kept)
        print(
            f"Found {len(kept)} samples "
            f"({n_paired} paired, {n_single} single-end) → {output[0]} "
            f"(skipped {n_blacklisted} of {len(BLACKLIST)} blacklisted)"
        )
