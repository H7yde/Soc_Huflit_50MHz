# HUFLIT 50 MHz SoC with CNN Accelerator

Project SoC FPGA chạy ở 50 MHz, tích hợp PicoRV32, các peripheral AXI/APB và bộ gia tốc CNN phân loại ảnh human/non-human.

## Kiến trúc CNN

RGB 32x32x3 -> Conv1 (3 to 4, kernel 3x3) -> MaxPool 2x2 -> Conv2 (4 to 4) -> MaxPool 2x2 -> Conv3 (4 to 4) -> MaxPool 2x2 -> Flatten 16 -> FC 16 to 1 -> classification.

Core CNN dùng FSM và một MAC mỗi chu kỳ để giảm tài nguyên synthesis.

## Mở project Vivado

Mở file SOC_HUFLIT_2026.xpr hoặc chạy Tcl:

    open_project SOC_HUFLIT_2026.xpr

Top-level là soc_top. Constraint clock 50 MHz nằm tại:

    SOC_HUFLIT_2026.srcs/constrs_1/new/soc_top.xdc

## Các file quan trọng

| File | Chức năng |
|---|---|
| SOC_HUFLIT_2026.srcs/sources_1/new/CNN.v | AXI4-Lite peripheral CNN |
| cnn_docx_reference.v | CNN FSM synthesizable |
| dma32_to_rgb24.v | Đổi stream 32-bit thành RGB 24-bit |
| conv1_rgb_weight.mem | 108 weight INT8 của Conv1 |
| conv2_weight.mem | 144 weight INT8 của Conv2 |
| conv3_weight.mem | 144 weight INT8 của Conv3 |
| fc_weight.mem | 16 weight INT8 của FC |
| Tb_CNN.v | Testbench CNN |
| soc_top.v | Top-level toàn SoC |

## Bản đồ địa chỉ CNN

CNN được ánh xạ tại base address 0x40004000.

| Địa chỉ | Chức năng |
|---|---|
| 0x40004000 - 0x40004BFC | 768 word ảnh, mỗi word 32-bit |
| 0x40004FF4 | RESULT, bit 0 là classification |
| 0x40004FF8 | STATUS, bit 0 là busy, bit 1 là done |
| 0x40004FFC | CONTROL, ghi bit 0 = 1 để START |

Một frame RGB 32x32 cần 3072 byte, tương đương 768 word 32-bit.

classification = 1 là human. classification = 0 là non-human.

## Luồng dữ liệu

CPU ghi 768 word qua AXI -> frame_mem[0:767] -> dma32_to_rgb24 -> 1024 pixel RGB 24-bit -> CNN FSM -> result_valid/classification -> CPU đọc RESULT/STATUS qua AXI.

Do một pixel RGB có 3 byte, dữ liệu có thể bị chia giữa hai word 32-bit. Module dma32_to_rgb24 xử lý việc ghép byte liên tục này.

## Weight và file .mem

Weight được train bằng Python/PyTorch, lượng tử hóa về INT8, sau đó ghi ra file .mem. Verilog nạp weight bằng system task readmemh.

Weight âm sử dụng dạng bù 2, ví dụ -1 = FF và -2 = FE.

Khi synthesis, cần thêm các file .mem vào Vivado dưới dạng Design Sources hoặc Memory Initialization Files.

## Mô phỏng CNN

Thêm vào Simulation Sources:

    CNN.v
    cnn_docx_reference.v
    dma32_to_rgb24.v
    Tb_CNN.v

Đặt top simulation là Tb_CNN.

Testbench sẽ đọc frame RGB, ghi 768 word qua AXI, ghi lệnh START, chờ STATUS.done, đọc classification và in PASS hoặc FAIL trên console.

Frame mô phỏng gồm human_frame.mem và nonhuman_frame.mem.

## Synthesis và implementation

1. Mở SOC_HUFLIT_2026.xpr.
2. Kiểm tra soc_top là top module.
3. Kiểm tra file .xdc đang active.
4. Kiểm tra các file .mem đã được thêm vào project.
5. Chạy Run Synthesis.
6. Chạy Run Implementation.
7. Kiểm tra Timing Summary.
8. Generate Bitstream.

Các thư mục build/cache Vivado được bỏ qua bằng .gitignore: SOC_HUFLIT_2026.cache, SOC_HUFLIT_2026.gen, SOC_HUFLIT_2026.hw, SOC_HUFLIT_2026.ip_user_files, SOC_HUFLIT_2026.runs và SOC_HUFLIT_2026.sim.

## Python và tài liệu

Các file train/export CNN nằm trong repository CNN_RTL:

    CNN_layer.py
    CNN_MEM.py
    export_cifar_frames.py
    tb_CNN.v

Thư mục KQ chứa hình ảnh, waveform và kết quả thí nghiệm. Thư mục Luanvan chứa tài liệu và báo cáo.

## Lưu ý

- CNN dùng fixed-point/INT8 nên kết quả có thể khác model floating-point.
- Thứ tự byte RGB phải thống nhất giữa Python, testbench, DMA và CNN.
- classification chỉ có ý nghĩa khi STATUS.done = 1.
- Nếu synthesis quá lâu, kiểm tra đang dùng core FSM tuần tự, không phải model cũ có task process_frame.
- Khi thay đổi weight, chạy lại simulation trước khi synthesis.

Repository: https://github.com/H7yde/Soc_Huflit_50MHz

