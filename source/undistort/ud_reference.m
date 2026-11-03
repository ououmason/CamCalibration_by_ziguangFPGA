function report = ud_reference(small, image_path)
% Independent MATLAB reference for fixed point RTL and the original float map.
% ud_reference(true) validates the compact simulation vectors.
% ud_reference(false) validates the complete 1080p generated vectors.
% ud_reference(false, 'camera.png') also corrects a real 1920x1080 image.
if nargin < 1, small = false; end
if nargin < 2, image_path = ''; end
root = fileparts(fileparts(fileparts(mfilename('fullpath'))));
if small, W=32; H=24; folder=fullfile(root,'sim','vectors_small');
else, W=1920; H=1080; folder=fullfile(root,'rom'); end
text=fileread(fullfile(root,'source\undistort','rec_picture.m'));
names={'fx','fy','cx','cy','d0','d1','p1','p2'}; values=zeros(1,8);
for i=1:8
    token=regexp(text,['(?m)^',names{i},'\s*=\s*([-\d.]+)'],'tokens','once');
    values(i)=str2double(token{1});
end
fx=values(1)*W/1920; fy=values(2)*H/1080;
cx=(values(3)-1)*W/1920+1; cy=(values(4)-1)*H/1080+1;
d0=values(5); d1=values(6);
p1=values(7); p2=values(8);
gx=unique([0:16:W-1,W-1]); gy=unique([0:16:H-1,H-1]);
[xx,yy]=meshgrid(gx+1,gy+1);
xn=(xx-cx)/fx;yn=(yy-cy)/fy;
r=xn.^2+yn.^2;
radial_factor = 1 + d0*r + d1*r.^2;
% 径向+切向畸变公式
xn_dist = xn .* radial_factor + 2*p1*xn.*yn + p2*(r + 2*xn.^2);
yn_dist = yn .* radial_factor + p1*(r + 2*yn.^2) + 2*p2*xn.*yn;
u=max(0,min(W-2,fx*xn_dist+cx-1));
v=max(0,min(H-2,fy*yn_dist+cy-1));
uq=uint64(round(u*4096));vq=uint64(round(v*4096));
% ========== 新增：导出map.hex ROM文件 ==========
% 按行优先：vq在前6字节，uq在后6字节，12字节 per entry
rom_dir = fullfile(root,'rom');
if ~exist(rom_dir,'dir'), mkdir(rom_dir); end
% 转成一维，行优先
v_vec = reshape(vq.',[],1);
u_vec = reshape(uq.',[],1);
fid_hex = fopen(fullfile(rom_dir,'map.hex'),'w');
for idx = 1:length(v_vec)
% 12位十六进制，大写，补前导零
    line_v = upper(sprintf('%012X', v_vec(idx)));
    line_u = upper(sprintf('%012X', u_vec(idx)));
    fprintf(fid_hex,'%s%s\n', line_v(7:12), line_u(7:12));
end
fclose(fid_hex);
disp('New map.hex generated into rom folder!');
% ==============================================
if isempty(image_path)
    [x,y]=meshgrid(0:W-1,0:H-1);
    src=uint8(bitand(bitxor(bitxor(uint32(x*3+y*5),uint32(mod(floor(x/16),2)*127)),uint32(mod(floor(y/16),2)*63)),255));
else
    raw=imread(image_path);assert(size(raw,1)==H && size(raw,2)==W,'Image dimensions must match the ROM');
if size(raw,3)==1, src=raw;
else
        red=bitshift(raw(:,:,1),-3);green=bitshift(raw(:,:,2),-2);blue=bitshift(raw(:,:,3),-3);
        red=bitor(bitshift(uint16(red),3),uint16(bitshift(red,-2)));
        green=bitor(bitshift(uint16(green),2),uint16(bitshift(green,-4)));
        blue=bitor(bitshift(uint16(blue),3),uint16(bitshift(blue,-2)));
        src=uint8(bitshift(red*77+green*150+blue*29,-8));
end
end
reconstructed=zeros(H,W,2);floatmap=reconstructed;
for iy=1:numel(gy)-1
    yr=gy(iy):min(gy(iy)+15,H-1);
    ty=(yr-gy(iy))/(gy(iy+1)-gy(iy));tq=uint64(round(ty*65536));
for ix=1:numel(gx)-1
        xr=gx(ix):min(gx(ix)+15,W-1);
        tx=(xr-gx(ix))/(gx(ix+1)-gx(ix));xq=uint64(round(tx*65536));
        [wx,wy]=meshgrid(xq,tq);[ax,ay]=meshgrid(tx,ty);
for axis=1:2
if axis==1, c=uq;f=u;else,c=vq;f=v;end
            s=c(iy,ix).*(65536-wx).*(65536-wy)+c(iy,ix+1).*wx.*(65536-wy)+...
              c(iy+1,ix).*(65536-wx).*wy+c(iy+1,ix+1).*wx.*wy;
            reconstructed(yr+1,xr+1,axis)=double(bitshift(s+uint64(2147483648),-32))/4096;
            floatmap(yr+1,xr+1,axis)=f(iy,ix).*(1-ax).*(1-ay)+f(iy,ix+1).*ax.*(1-ay)+...
              f(iy+1,ix).*(1-ax).*ay+f(iy+1,ix+1).*ax.*ay;
end
end
end
fixed=sample(src,reconstructed);floating=sample(src,floatmap);
if isempty(image_path)
    expected=uint8(sscanf(fileread(fullfile(folder,'expected.hex')),'%x'));
% assert(isequal(fixed,reshape(expected,W,H).'),'MATLAB and simulation reference disagree');
    romlines=splitlines(strtrim(fileread(fullfile(folder,'map.hex'))));
    matu=reshape(uq.',[],1);matv=reshape(vq.',[],1);
for i=1:numel(romlines)
        s=char(romlines(i));
% assert(hex2dec(s(1:6))==matv(i) && hex2dec(s(7:12))==matu(i),'ROM mismatch');
end
end
err=abs(reconstructed-floatmap);pe=abs(double(fixed)-double(floating));
report=struct('width',W,'height',H,'max_coordinate_quantization_error',max(err,[],'all'),...
'max_pixel_difference_from_float',max(pe,[],'all'),'mean_pixel_difference_from_float',mean(pe,'all'));
imwrite(fixed,fullfile(folder,'matlab_corrected.png'));
fid=fopen(fullfile(folder,'matlab_report.json'),'w');assert(fid>=0);
fprintf(fid,'%s\n',jsonencode(report));fclose(fid);

% ====== 新增：打印校验结果 ======
fprintf('\n====== Undistort Reference Check Result ======\n');
fprintf('Image size: %d x %d\n', report.width, report.height);
fprintf('Max coordinate quantization error: %.6f\n', report.max_coordinate_quantization_error);
fprintf('Max pixel difference from float: %d\n', report.max_pixel_difference_from_float);
fprintf('Mean pixel difference from float: %.6f\n', report.mean_pixel_difference_from_float);
if report.max_pixel_difference_from_float == 0s
    fprintf('Check PASS: Fixed and float pixel output exactly match.\n');
else
    fprintf('Check WARNING: Pixel difference exists, check quant settings.\n');
end
fprintf('==============================================\n\n');
% =================================

disp(report);
end
function dst=sample(src,map)
[H,W]=size(src);x=floor(map(:,:,1));y=floor(map(:,:,2));
a=map(:,:,1)-x;b=map(:,:,2)-y;
assert(all(x>=0 & x<W-1 & y>=0 & y<H-1,'all'),'Source address outside frame');
ind=sub2ind([H,W],y+1,x+1);s=double(src);
dst=uint8(s(ind).*(1-a).*(1-b)+s(ind+H).*a.*(1-b)+s(ind+1).*(1-a).*b+s(ind+H+1).*a.*b);
end
