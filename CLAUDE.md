# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Configure and build
mkdir -p build && cd build
cmake .. [-DCMAKE_INSTALL_PREFIX=...]
make [-j$(nproc)]

# Install
make install

# Build and run tests (Protonect example)
cmake .. -DBUILD_EXAMPLES=ON
make Protonect

# Build streamer/recorder tools
cmake .. -DBUILD_STREAMER_RECORDER=ON
make ProtonectSR

# Generate documentation
make doc
```

## Common CMake Options

| Option | Default | Description |
|--------|---------|-------------|
| `BUILD_SHARED_LIBS` | ON | Build shared or static libraries |
| `BUILD_EXAMPLES` | ON | Build Protonect example |
| `BUILD_OPENNI2_DRIVER` | ON | Build OpenNI2 driver |
| `BUILD_STREAMER_RECORDER` | OFF | Build streamer_recorder tools |
| `ENABLE_OPENGL` | ON | Enable OpenGL depth processing |
| `ENABLE_OPENCL` | ON | Enable OpenCL depth processing |
| `ENABLE_CUDA` | ON | Enable CUDA depth processing (NVIDIA) |
| `ENABLE_VAAPI` | ON | Enable VA-API JPEG decoding (Intel) |
| `ENABLE_TEGRAJPEG` | ON | Enable Tegra hardware JPEG support |
| `ENABLE_CXX11` | OFF | Enable C++11 support |

## Project Architecture

### Core Structure
- **libfreenect2**: Main library for Kinect for Windows v2 (K4W2) devices
- **Protonect**: Main example application and test program
- **streamer_recorder**: Tools for streaming and recording Kinect data

### Pipeline Architecture
The library supports multiple depth processing pipelines:
- **CPU** (`cpu_depth_packet_processor.cpp`): Software-based depth processing
- **OpenGL** (`opengl_depth_packet_processor.cpp`): GPU-accelerated using OpenGL 3.1+
- **OpenCL** (`opencl_depth_packet_processor.cpp`, `opencl_kde_depth_packet_processor.cpp`): GPU/CPU acceleration via OpenCL
- **CUDA** (`cuda_depth_packet_processor.cu`, `cuda_kde_depth_packet_processor.cu`): NVIDIA GPU acceleration
- **VideoToolbox** (`vt_rgb_packet_processor.cpp`): macOS hardware JPEG decoding
- **VAAPI** (`vaapi_rgb_packet_processor.cpp`): Intel VAAPI JPEG decoding
- **TegraJPEG** (`tegra_jpeg_rgb_processor.cpp`): NVIDIA Jetson hardware JPEG

### Key Components
1. **USB/Protocol Layer**: Handles USB communication via libusb, protocol commands/responses
2. **Packet Processors**: RGB and depth packet processors for each pipeline
3. **Registration**: Core registration of RGB and depth images
4. **Frame Listener**: Frame capture API for applications

### Build System
- CMake-based with custom Find modules in `cmake_modules/`
- Generates config files for downstream projects (`freenect2Config.cmake`)
- Supports out-of-tree builds with `freenect2_ROOT_DIR`

## API Documentation
https://openkinect.github.io/libfreenect2/
