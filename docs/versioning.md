# Versioning and releases

## Canonical version

The root `VERSION` file is the single source of truth for the OSymbiote project version. It uses three-component Semantic Versioning (`MAJOR.MINOR.PATCH`), currently `0.4.0`.

Both image builders copy this value into `/etc/osymbiote/version` in the guest. `GET /health` reports that value as its `version`. A fallback is retained for manually assembled or older images that lack the version file.

Individual files are not assigned independent release versions. Git records file-level revisions and history; the project version applies to the repository release as a whole. Documentation describes the current release and should be updated in the same change as behavior it documents.

## Semantic version policy

The project is pre-1.0. Interfaces may change between minor releases; stability is not guaranteed. Where SemVer conventions are applied:

- Patch: compatible fixes and documentation corrections.
- Minor: new capabilities or compatible interface additions.
- Major: incompatible changes to behavior or public interfaces.

If compatibility impact is unclear, document it in the changelog and API reference rather than implying stability.

## Release checklist

1. Update `VERSION` once for the release.
2. Add user-visible changes and compatibility notes to `CHANGELOG.md`.
3. Check that both builders package the canonical version and `/health` reports it.
4. Build applicable targets and report which emulator/hardware runtime checks passed.
5. Review documentation links and verify feature claims against implementation.
6. Commit the release state and create a Git tag using `vMAJOR.MINOR.PATCH`.

Generated images and host `data/` are not versioned in Git. Version them separately only if a future release process introduces signed, published artifacts.
