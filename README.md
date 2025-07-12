Poor GI
===

A basic implementation of Screen Space Global Illumination (SSGI) for Unity URP.

![preview-sponza](Pictures/preview-sponza.png)

Core Approach
-------------
- Low-resolution processing (1/4 resolution) for performance
- Horizon-based ambient occlusion for directional visibility estimation
- Global illumination is stored as irradiance encoded in 4 spherical harmonics (SH) coefficients + light color ([ref. Half Life 2: Shading](https://drivers.amd.com/developer/gdc/D3DTutorial10_Half-Life2_Shading.pdf))
- Bilateral blur to denoise lighting while preserving edges ([ref. Lords of the Fallen: Volumetric Lighting](https://www.slideshare.net/slideshow/volumetric-lighting-for-many-lights-in-lords-of-the-fallen/34507223))
- Bilateral upscaling to reconstruct lighting at full resolution

Notes
-----
- Designed for experimentation and learning rather than production use

License
-------
This project is MIT License - see the [LICENSE](LICENSE) file for details
