# Area efficient compression of brain floating point fmap values
Implemented a compression–decompression chain for BF16 values using Zero Run-Length Encoding (ZRLE) and Delta Encoding, with AXI-Stream wrappers in Verilog for both the compressor and decompressor. The design was tested on 100 ReLU-activated BF16 inputs extracted using PyTorch from a pretrained ResNet-34 model trained on ImageNet.
Features
BF16-aware compression and decompression pipeline
Zero Run-Length Encoding (ZRLE) for sparse ReLU activations
Delta Encoding for exponent redundancy reduction
Variable-length bit packing and unpacking
AXI4-Stream wrappers for compressor and decompressor
Fully implemented in Verilog
Functional verification using real neural network activation data 
Compression Flow
ZRLE Encoder
Detects consecutive zero values and encodes run lengths efficiently.
Delta Encoder
Compresses non-zero BF16 values using exponent delta encoding relative to bias 127.
Packer
Packs variable-length compressed symbols into fixed 16-bit output words.
Decompression Flow
Unpacker
Extracts compressed symbols from the packed bitstream.
ZRLE Decoder
Expands zero-run encoded sequences.
Delta Decoder
Reconstructs original BF16 values from compressed delta codes.
AXI Stream Support

AXI4-Stream wrappers are implemented for both compressor and decompressor modules, enabling integration with FPGA/SoC dataflow systems and DMA-based architectures.

Testing

The design was tested on:

Synthetic BF16 test vectors
100 ReLU-activated BF16 values extracted from a pretrained ResNet-34 model trained on ImageNet using PyTorch

Simulation verified successful end-to-end reconstruction of the original inputs after compression and decompression.

Results

For a sample test containing 9 BF16 values, the compressor produced 4 compressed outputs, achieving a compression ratio of 2.25.

Applications
Edge AI accelerators
Near-memory / in-memory computing
CNN feature map compression
FPGA-based AI systems
Reference

Bai-Kui Yan and Shang-Jang Ruan,
Area Efficient Compression for Floating-Point Feature Maps in Convolutional Neural Network Accelerators
