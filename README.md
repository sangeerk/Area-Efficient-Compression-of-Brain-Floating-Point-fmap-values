# Area-Efficient-Compression-of-Brain-Floating-Point-fmap-values
Implemented a compression–decompression chain for BF16 values using Zero Run-Length Encoding (ZRLE) and Delta Encoding, with AXI-Stream wrappers in Verilog for both the compressor and decompressor. The design was tested on 100 ReLU-activated BF16 inputs extracted using PyTorch from a pretrained ResNet-34 model trained on ImageNet.
