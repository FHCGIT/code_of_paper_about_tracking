function [positions, fps] = dsst(params)

% [positions, fps] = dsst(params)

% parameters
padding = params.padding;                         	%extra area surrounding the target
output_sigma_factor = params.output_sigma_factor;	%spatial bandwidth (proportional to target)
lambda = params.lambda;
learning_rate = params.learning_rate;
nScales = params.number_of_scales;
scale_step = params.scale_step;
scale_sigma_factor = params.scale_sigma_factor;
scale_model_max_area = params.scale_model_max_area;

video_path = params.video_path;
img_files = params.img_files;
pos = floor(params.init_pos);
target_sz = floor(params.wsize);       %上面都是各种参数

visualization = params.visualization;   %可视化

num_frames = numel(img_files);      %帧数

init_target_sz = target_sz;       %初始化大小

% target size att scale = 1
base_target_sz = target_sz;    

% window size, taking padding into account
sz = floor(base_target_sz * (1 + padding));    %加padding，学习背景和目标

% desired translation filter output (gaussian shaped), bandwidth
% proportional to target size
output_sigma = sqrt(prod(base_target_sz)) * output_sigma_factor;
[rs, cs] = ndgrid((1:sz(1)) - floor(sz(1)/2), (1:sz(2)) - floor(sz(2)/2));
y = exp(-0.5 * (((rs.^2 + cs.^2) / output_sigma^2)));
yf = single(fft2(y));       %期望的输出，这里从double转换成single,double 128位，sinle是64位的


% desired scale filter output (gaussian shaped), bandwidth proportional to
% number of scales
scale_sigma = nScales/sqrt(33) * scale_sigma_factor;
ss = (1:nScales) - ceil(nScales/2);
ys = exp(-0.5 * (ss.^2) / scale_sigma^2);
ysf = single(fft(ys));          %尺寸滤波器的输出，是一个一维的高斯

% store pre-computed translation filter cosine window
cos_window = single(hann(sz(1)) * hann(sz(2))');     %汉明窗，主要避免傅里叶变换时边缘的影响

% store pre-computed scale filter cosine window
%尺寸也是加窗的，如果是偶数个，那么hann要加个1，然后从2开始取
if mod(nScales,2) == 0
    scale_window = single(hann(nScales+1));
    scale_window = scale_window(2:end);
else
    scale_window = single(hann(nScales));     
    
end;

% scale factors
%这里是计算调整的尺寸的比例.
ss = 1:nScales;
scaleFactors = scale_step.^(ceil(nScales/2) - ss);

% compute the resize dimensions used for feature extraction in the scale estimation
scale_model_factor = 1;      
if prod(init_target_sz) > scale_model_max_area
    scale_model_factor = sqrt(scale_model_max_area/prod(init_target_sz));
end
scale_model_sz = floor(init_target_sz * scale_model_factor);

currentScaleFactor = 1;

% to calculate precision
positions = zeros(numel(img_files), 4);

% to calculate FPS
time = 0;

% find maximum and minimum scales   这算出一个最大一个最小
im = imread([video_path img_files{1}]);
min_scale_factor = scale_step ^ ceil(log(max(5 ./ sz)) / log(scale_step));
max_scale_factor = scale_step ^ floor(log(min([size(im,1) size(im,2)] ./ base_target_sz)) / log(scale_step));

for frame = 1:num_frames,
    %load image
    im = imread([video_path img_files{frame}]);

    tic;
    
    if frame > 1
        
        % extract the test sample feature map for the translation filter
        xt = get_translation_sample(im, pos, sz, currentScaleFactor, cos_window);
        
        % calculate the correlation response of the translation filter
        xtf = fft2(xt);      %依然是28维
        response = real(ifft2(sum(hf_num .* xtf, 3) ./ (hf_den + lambda)));   %这里是乘起来，然后再复频域想加，完了之后再做ifft取实部
        
        % find the maximum translation response          %相应的最大点
        [row, col] = find(response == max(response(:)), 1);
        
        % update the position           %根据这个最大点然后再去确定尺寸
        pos = pos + round((-sz/2 + [row, col]) * currentScaleFactor);
        
        % extract the test sample feature map for the scale filter
        % 获得scale feature  
        xs = get_scale_sample(im, pos, base_target_sz, currentScaleFactor * scaleFactors, scale_window, scale_model_sz);
        
        % calculate the correlation response of the scale filter
        xsf = fft(xs,[],2);  
        scale_response = real(ifft(sum(sf_num .* xsf, 1) ./ (sf_den + lambda)));   %求最大响应因子，这里的样本稍多一点，因为Fhog提取的比较多，一个尺度提取了几百个特征
        
        % find the maximum scale response
        recovered_scale = find(scale_response == max(scale_response(:)), 1);        %对应的尺寸索引
        
        % update the scale
        currentScaleFactor = currentScaleFactor * scaleFactors(recovered_scale);     %更新尺寸
        if currentScaleFactor < min_scale_factor                                     %处理极值
            currentScaleFactor = min_scale_factor;
        elseif currentScaleFactor > max_scale_factor
            currentScaleFactor = max_scale_factor;
        end
    end
    
    % extract the training sample feature map for the translation filter
    % 这里得到的是特征图，27维fhog和1维的灰度,都是加了窗之后的。  共28维特征
    xl = get_translation_sample(im, pos, sz, currentScaleFactor, cos_window);
    
    % calculate the translation filter update  预测的滤波器更新，这
    xlf = fft2(xl);
    new_hf_num = bsxfun(@times, yf, conj(xlf));      %分子，还是28维的复数
    new_hf_den = sum(xlf .* conj(xlf), 3);          %分母，这里把每一维对应位置加起来了，因为自相关得到的是实数可以直接加
    
    % extract the training sample feature map for the scale filter
    %这里得到的是scale用的特征，33个尺度都得到特征，
    %每个尺度计算fhog之前都会resize到一个固定尺寸，这里是19*26,那么得到的Fhog特征是19/4*26/4*31=744维的特征，串联起来当做一列
    xs = get_scale_sample(im, pos, base_target_sz, currentScaleFactor * scaleFactors, scale_window, scale_model_sz);
    
    % calculate the scale filter update
    xsf = fft(xs,[],2);          %没一行做fft
    new_sf_num = bsxfun(@times, ysf, conj(xsf));   %算互相关
    new_sf_den = sum(xsf .* conj(xsf), 1);     %自相关，然后每一列都加起来，是1*33维的一个向量
    
    
    if frame == 1       %初始化
        % first frame, train with a single image
        hf_den = new_hf_den;
        hf_num = new_hf_num;
        
        sf_den = new_sf_den;
        sf_num = new_sf_num;
    else
        % subsequent frames, update the model，更新模型
        hf_den = (1 - learning_rate) * hf_den + learning_rate * new_hf_den;
        hf_num = (1 - learning_rate) * hf_num + learning_rate * new_hf_num;
        sf_den = (1 - learning_rate) * sf_den + learning_rate * new_sf_den;
        sf_num = (1 - learning_rate) * sf_num + learning_rate * new_sf_num;
    end
    
    % calculate the new target size
    target_sz = floor(base_target_sz * currentScaleFactor);
    
    %save position
    positions(frame,:) = [pos target_sz];
    
    time = time + toc;
    
    
    %visualization   %可视化
    if visualization == 1
        rect_position = [pos([2,1]) - target_sz([2,1])/2, target_sz([2,1])];
        if frame == 1,  %first frame, create GUI
            figure('Name',['Tracker - ' video_path]);
            im_handle = imshow(uint8(im), 'Border','tight', 'InitialMag', 100 + 100 * (length(im) < 500));
            rect_handle = rectangle('Position',rect_position, 'EdgeColor','g');
            text_handle = text(10, 10, int2str(frame));
            set(text_handle, 'color', [0 1 1]);
        else
            try  %subsequent frames, update GUI
                set(im_handle, 'CData', im)
                set(rect_handle, 'Position', rect_position)
                set(text_handle, 'string', int2str(frame));
            catch
                return
            end
        end
        
        drawnow
%         pause
    end
end

fps = num_frames/time;