---
description: Materialise the wiki media cache into the vault (images, audio, video)
---
The vault holds a committed manifest but no media bytes. Fetch them locally.

1. The vault is `.prodev-vault/noclip-protocol-vault` (relative to this repo).
   Read `<vault>/60-lore/FETCH-MEDIA.md`.
2. Follow it exactly: `media verify` → `media fetch --missing --jobs 4` →
   `media verify`.
3. The fetch is ~645 MB and takes 15–30 minutes. Run it in the background and
   report progress if it is still running when you check.
4. Do not commit anything. `60-lore/_media/` is gitignored on purpose.
5. Report exactly three numbers from the final verify: present, missing, on
   disk. Then name any file in `_media/failures.json`.

If `lore-ingest` is missing, say so and stop — do not fall back to scraping the
wiki by hand, that loses the manifest's revid mapping.

Additional context: $ARGUMENTS
