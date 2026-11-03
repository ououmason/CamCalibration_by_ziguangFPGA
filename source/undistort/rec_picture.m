% 图像径向+切向畸变校正程序
% 算法：逆向映射 + 16像素稀疏坐标网格 + 坐标双线性插值 + 像素双线性插值
% 畸变模型：二阶径向畸变 + 切向畸变（MATLAB cameraParams标准模型）
% 思路：
%   1) 只在每隔16个像素的网格点上计算一次畸变映射坐标，形成稀疏查找表 LUT。
%   2) 遍历校正后图像的每个像素时，先查周围4个网格点。
%   3) 对这4个网格点的源图坐标做双线性插值，恢复当前像素的源图坐标(u,v)。
%   4) 再用(u,v)在原始畸变图中做像素双线性插值，得到校正后像素值。
close all; clear; clc;
%% ========== 1. 相机参数配置 ==========
% 相机内参：fx/fy为像素焦距，cx/cy为主点坐标（光心在图像中的像素位置）
fx = 2448.6;
fy = 2450.4;
cx = 1054.7;
cy = 704.3701;
% 二阶径向畸变系数：d0=k1对应r^2项，d1=k2对应r^4项（由镜头标定得到）
d0 = -0.4996;
d1 = 0.3758;
% 切向畸变系数 p1,p2（来自MATLAB标定结果 TangentialDistortion [0.0031,0.0018]）
p1 = 0.0031;
p2 = 0.0018;
% 稀疏网格间隔。GRID_STEP=16表示每16个像素存一次映射坐标。
GRID_STEP = 16;
%% ========== 2. 读取图像并初始化 ==========
I_Src = imread('img/img1.png');          % 读取畸变原图
[ROW, COL, channel] = size(I_Src);         % 自动获取图像尺寸（1080P：ROW=1080, COL=1920）
I_Dst = zeros(ROW, COL, channel, 'uint8'); % 初始化校正后图像矩阵
fprintf('Input image size: %d x %d, channel = %d\n', COL, ROW, channel);
%% ========== 3. 生成16像素稀疏坐标查找表 LUT ==========
% grid_x/grid_y 是校正后图像中的稀疏网格坐标。
% 例如列方向为 1,17,33,...，最后强制补到COL，保证右边界可插值。
grid_x = 1 : GRID_STEP : COL;
grid_y = 1 : GRID_STEP : ROW;
if grid_x(end) ~= COL
    grid_x = [grid_x, COL];
end
if grid_y(end) ~= ROW
    grid_y = [grid_y, ROW];
end
GRID_COL = length(grid_x);
GRID_ROW = length(grid_y);
% map_grid_u/map_grid_v 是稀疏坐标LUT。
% LUT中每个点存的是：该校正后网格点应该去畸变原图中的哪个浮点坐标采样。
map_grid_u = zeros(GRID_ROW, GRID_COL);
map_grid_v = zeros(GRID_ROW, GRID_COL);
for gy = 1 : GRID_ROW
for gx = 1 : GRID_COL
        x = grid_x(gx);
        y = grid_y(gy);
% 网格点坐标 -> 归一化相机坐标
        x_norm = (x - cx) / fx;
        y_norm = (y - cy) / fy;
% 径向+切向畸变模型
        r_square = x_norm^2 + y_norm^2;
        radial_factor = 1 + d0 * r_square + d1 * r_square^2;
        x_dist_norm = x_norm * radial_factor + 2*p1*x_norm*y_norm + p2*(r_square + 2*x_norm^2);
        y_dist_norm = y_norm * radial_factor + p1*(r_square + 2*y_norm^2) + 2*p2*x_norm*y_norm;
% 畸变归一化坐标 -> 原图像素坐标
        u = fx * x_dist_norm + cx;
        v = fy * y_dist_norm + cy;
% 边界保护：限制到[1, COL-1]和[1, ROW-1]，保证后续x0+1/y0+1不越界。
        map_grid_u(gy, gx) = max(1.0, min(u, COL - 1.0));
        map_grid_v(gy, gx) = max(1.0, min(v, ROW - 1.0));
end
end
fprintf('Sparse grid size: %d x %d, total control points = %d\n', ...
    GRID_COL, GRID_ROW, GRID_COL * GRID_ROW);
%% ========== 4. 坐标误差评估 ==========
% 评估目的：判断16像素稀疏网格是否足够精确。
% 做法：
%   1) map_full_u/map_full_v：每个像素直接用畸变公式计算，作为完整坐标参考。
%   2) map_rebuild_u/map_rebuild_v：每个像素只通过稀疏LUT查表+坐标插值得到。
%   3) 二者相减，统计坐标误差，单位是pixel。
map_full_u = zeros(ROW, COL);
map_full_v = zeros(ROW, COL);
map_rebuild_u = zeros(ROW, COL);
map_rebuild_v = zeros(ROW, COL);
for x = 1 : COL
for y = 1 : ROW
% 完整逐像素公式映射，作为误差评估参考。
        x_norm = (x - cx) / fx;
        y_norm = (y - cy) / fy;
        r_square = x_norm^2 + y_norm^2;
        radial_factor = 1 + d0 * r_square + d1 * r_square^2;
        x_dist_norm = x_norm * radial_factor + 2*p1*x_norm*y_norm + p2*(r_square + 2*x_norm^2);
        y_dist_norm = y_norm * radial_factor + p1*(r_square + 2*y_norm^2) + 2*p2*x_norm*y_norm;
        u_full = fx * x_dist_norm + cx;
        v_full = fy * y_dist_norm + cy;
        u_full = max(1.0, min(u_full, COL - 1.0));
        v_full = max(1.0, min(v_full, ROW - 1.0));
        map_full_u(y, x) = u_full;
        map_full_v(y, x) = v_full;
% 用和FPGA主流程一致的方式：查4个稀疏网格点，再对坐标做双线性插值。
        gx = floor((x - 1) / GRID_STEP) + 1;
        gy = floor((y - 1) / GRID_STEP) + 1;
        gx = min(gx, GRID_COL - 1);
        gy = min(gy, GRID_ROW - 1);
        x_left  = grid_x(gx);
        x_right = grid_x(gx + 1);
        y_top   = grid_y(gy);
        y_bot   = grid_y(gy + 1);
        tx = (x - x_left) / (x_right - x_left);
        ty = (y - y_top)  / (y_bot - y_top);
        u00 = map_grid_u(gy,     gx);
        u10 = map_grid_u(gy,     gx + 1);
        u01 = map_grid_u(gy + 1, gx);
        u11 = map_grid_u(gy + 1, gx + 1);
        v00 = map_grid_v(gy,     gx);
        v10 = map_grid_v(gy,     gx + 1);
        v01 = map_grid_v(gy + 1, gx);
        v11 = map_grid_v(gy + 1, gx + 1);
        u_top = u00 * (1 - tx) + u10 * tx;
        u_bot = u01 * (1 - tx) + u11 * tx;
        v_top = v00 * (1 - tx) + v10 * tx;
        v_bot = v01 * (1 - tx) + v11 * tx;
        map_rebuild_u(y, x) = u_top * (1 - ty) + u_bot * ty;
        map_rebuild_v(y, x) = v_top * (1 - ty) + v_bot * ty;
end
end
coord_err_u = abs(map_full_u - map_rebuild_u);
coord_err_v = abs(map_full_v - map_rebuild_v);
coord_err = sqrt(coord_err_u.^2 + coord_err_v.^2);
coord_err_sorted = sort(coord_err(:));
idx_95 = max(1, ceil(0.95 * numel(coord_err_sorted)));
mean_err = mean(coord_err(:));
p95_err = coord_err_sorted(idx_95);
max_err = max(coord_err(:));
max_u_err = max(coord_err_u(:));
max_v_err = max(coord_err_v(:));
fprintf('\n========== Sparse Grid Coordinate Error (Radial+Tangential) ==========' );
fprintf('\nGRID_STEP                = %d pixels', GRID_STEP);
fprintf('\nMean coordinate error    = %.6f pixel', mean_err);
fprintf('\n95%% coordinate error     = %.6f pixel', p95_err);
fprintf('\nMax coordinate error     = %.6f pixel', max_err);
fprintf('\nMax u error              = %.6f pixel', max_u_err);
fprintf('\nMax v error              = %.6f pixel\n\n', max_v_err);
% 输出误差报告文本，方便后续比较GRID_STEP=16和GRID_STEP=8。
fid = fopen('sparse_grid_error_report.txt', 'w');
if fid ~= -1
    fprintf(fid, 'Image size: %d x %d\n', COL, ROW);
    fprintf(fid, 'GRID_STEP: %d\n', GRID_STEP);
    fprintf(fid, 'Sparse grid size: %d x %d\n', GRID_COL, GRID_ROW);
    fprintf(fid, 'Total control points: %d\n', GRID_COL * GRID_ROW);
    fprintf(fid, 'Mean coordinate error: %.9f pixel\n', mean_err);
    fprintf(fid, '95%% coordinate error: %.9f pixel\n', p95_err);
    fprintf(fid, 'Max coordinate error: %.9f pixel\n', max_err);
    fprintf(fid, 'Max u error: %.9f pixel\n', max_u_err);
    fprintf(fid, 'Max v error: %.9f pixel\n', max_v_err);
    fprintf(fid, 'k1=%g, k2=%g, p1=%g, p2=%g\n',d0,d1,p1,p2);
    fclose(fid);
end
figure('Name','16像素稀疏网格坐标误差热力图');
imagesc(coord_err);
axis image;
colorbar;
title('坐标误差 sqrt((u_{full}-u_{sparse})^2 + (v_{full}-v_{sparse})^2) / pixel');
xlabel('x / pixel');
ylabel('y / pixel');
%% ========== 5. 查表 + 坐标插值 + 像素双线性插值 ==========
for x = 1 : COL      % x：图像列方向（横坐标）
for y = 1 : ROW  % y：图像行方向（纵坐标）
        %% Step1：根据当前输出像素，定位它所在的16x16网格单元
% gx/gy 是左上角控制点在LUT中的索引。
% 例如 x=20 时位于 grid_x=17 和 grid_x=33 之间，gx指向17这个控制点。
        gx = floor((x - 1) / GRID_STEP) + 1;
        gy = floor((y - 1) / GRID_STEP) + 1;
% 如果当前像素落在最后一个补边界网格点上，则使用最后一个有效网格单元。
        gx = min(gx, GRID_COL - 1);
        gy = min(gy, GRID_ROW - 1);
        x_left  = grid_x(gx);
        x_right = grid_x(gx + 1);
        y_top   = grid_y(gy);
        y_bot   = grid_y(gy + 1);
        %% Step2：计算当前像素在网格单元内部的相对位置
% tx/ty 是坐标插值权重，范围通常为0~1。
% FPGA实现时，若GRID_STEP固定为16，tx/ty可用低4位和右移实现。
        tx = (x - x_left) / (x_right - x_left);
        ty = (y - y_top)  / (y_bot - y_top);
        %% Step3：查稀疏坐标表，读取周围4个控制点
% 注意：这里查出来的是源图坐标(u,v)，不是像素颜色。
% P00: 左上控制点，P10: 右上控制点，P01: 左下控制点，P11: 右下控制点。
        u00 = map_grid_u(gy,     gx);
        u10 = map_grid_u(gy,     gx + 1);
        u01 = map_grid_u(gy + 1, gx);
        u11 = map_grid_u(gy + 1, gx + 1);
        v00 = map_grid_v(gy,     gx);
        v10 = map_grid_v(gy,     gx + 1);
        v01 = map_grid_v(gy + 1, gx);
        v11 = map_grid_v(gy + 1, gx + 1);
        %% Step4：对坐标做双线性插值，恢复当前像素的源图坐标(u,v)
% 先在水平方向插值，再在垂直方向插值。
% 这一步对应FPGA中的"稀疏LUT + 坐标插值"模块。
        u_top = u00 * (1 - tx) + u10 * tx;
        u_bot = u01 * (1 - tx) + u11 * tx;
        u = u_top * (1 - ty) + u_bot * ty;
        v_top = v00 * (1 - tx) + v10 * tx;
        v_bot = v01 * (1 - tx) + v11 * tx;
        v = v_top * (1 - ty) + v_bot * ty;
% 坐标插值后再次做边界保护，避免浮点误差导致索引越界。
        u = max(1.0, min(u, COL - 1.0));
        v = max(1.0, min(v, ROW - 1.0));
        %% Step5：根据源图坐标(u,v)，计算像素插值所需整数坐标和权重
        x0 = floor(u);  % 原图左侧整数列
        y0 = floor(v);  % 原图上方整数行
        du = u - x0;    % 原图列方向像素插值权重
        dv = v - y0;    % 原图行方向像素插值权重
        %% Step6：对原图像素做双线性插值
% 四个邻域像素：
%   I00 = I_Src(y0,   x0)
%   I10 = I_Src(y0,   x0+1)
%   I01 = I_Src(y0+1, x0)
%   I11 = I_Src(y0+1, x0+1)
% 这里做的是"像素值插值"，和上面的"坐标插值"是两个不同阶段。
        pix_00 = double(I_Src(y0,     x0,     :)) * (1 - du) * (1 - dv);
        pix_10 = double(I_Src(y0,     x0 + 1, :)) * du       * (1 - dv);
        pix_01 = double(I_Src(y0 + 1, x0,     :)) * (1 - du) * dv;
        pix_11 = double(I_Src(y0 + 1, x0 + 1, :)) * du       * dv;
        I_Dst(y, x, :) = uint8(pix_00 + pix_10 + pix_01 + pix_11);
end
end
%% ========== 6. 结果可视化 ==========
figure('Name','畸变校正对比（径向+切向）');
subplot(1,2,1);
imshow(I_Src);
title('畸变原图像');
subplot(1,2,2);
imshow(I_Dst);
title('16像素稀疏网格校正后图像（含切向畸变）');
figure('Name','16像素稀疏网格校正后完整图像（径向+切向）');
imshow(I_Dst);
% ========== 保存校正输出图像 ==========
imwrite(I_Dst, '../img_evaluation/corrected_img1_rad_tan.png');
fprintf('矫正图像已保存：../img_evaluation/corrected_img1_rad_tan.png\n');
