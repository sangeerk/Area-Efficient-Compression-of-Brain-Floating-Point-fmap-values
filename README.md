# Area efficient compression of brain floating point fmap values
Implemented a compression–decompression chain for BF16 values using Zero Run-Length Encoding (ZRLE) and Delta Encoding, with AXI-Stream wrappers in Verilog for both the compressor and decompressor. The design was tested on 100 ReLU-activated BF16 inputs extracted using PyTorch from a pretrained ResNet-34 model trained on ImageNet.

Reference

Bai-Kui Yan and Shang-Jang Ruan,
Area Efficient Compression for Floating-Point Feature Maps in Convolutional Neural Network Accelerators
