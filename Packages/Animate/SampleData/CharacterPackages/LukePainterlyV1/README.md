# LukePainterlyV1 Fixture Notes

This sample package includes a small proof-of-concept layer set under `parts/`.

- The layer PNGs are derived from `poses/luke-painterly-frontal-base.png`.
- Each part asset is a full-size transparent canvas with only one cropped region filled in.
- This keeps all part layers aligned in the same coordinate space, which is useful for early renderer tests.
- The crops are pragmatic rectangles, not production segmentation masks.
- The current runtime schema does not yet have a dedicated `bodyPart` asset role, so these test layers are encoded as `costumeOverlay` assets with `partType` populated.
