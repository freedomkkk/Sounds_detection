function signal_enhan=cgmm_mvdr(path,  iters)

%  apply mvdr based on mask estimated by cgmm
num_iters=iters;
frame_length = 1024;
fft_length   = 1024;
frame_shift  = 256;
theta        = 10^-6;
hanning_wnd  = hanning(frame_length, 'periodic');

%samples =audio_data;
samples = audioread(path);
% [audio_raw,channels]=audio_data;

for ch =1:4
    frames=enframe(samples(:,ch),hanning_wnd, frame_shift);
    frames_size = size(frames);
    frames_padding = zeros(frames_size(1), fft_length);
    frames_padding(:, 1: frame_length) = frames;
    spectrums(:, :, ch) = rfft(frames_padding, fft_length, 2);
end
    

specs = permute(spectrums, [3, 1, 2]);
[num_channels, num_frames, num_bins] = size(specs);

% CGMM parameters
lambda_noise = zeros(num_frames, num_bins);
lambda_noisy = zeros(num_frames, num_bins);
phi_noise    = ones(num_frames, num_bins);
phi_noisy    = ones(num_frames, num_bins);
R_noise      = zeros(num_channels, num_channels, num_bins);
R_noisy      = zeros(num_channels, num_channels, num_bins);

% init R_noisy R_noise
for f = 1: num_bins
    R_noisy(:, :, f) = specs(:, :, f) * specs(:, :, f)' / num_frames;
    R_noise(:, :, f) = eye(num_channels, num_channels);
end

% precompute y^H * y
yyh = zeros(num_channels, num_channels, num_frames, num_bins);

for f = 1: num_bins
    for t = 1: num_frames
        yyh(:, :, t, f) = specs(:, t, f) * specs(:, t, f)';
    end
end

% init phi
for f = 1: num_bins
    
    R_noisy_onbin = stab(R_noisy(:, :, f), theta, num_channels);
    R_noise_onbin = stab(R_noise(:, :, f), theta, num_channels);

    R_noisy_inv = inv(R_noisy_onbin);
    R_noise_inv = inv(R_noise_onbin);

    for t = 1: num_frames
        corre   = yyh(:, :, t, f);
        phi_noise(t, f) = real(trace(corre * R_noise_inv) / num_channels);
        phi_noisy(t, f) = real(trace(corre * R_noisy_inv) / num_channels);
    end
end

% start CGMM training
p_noise = ones(num_frames, num_bins);
p_noisy = ones(num_frames, num_bins);

for iter = 1: num_iters

    for f = 1: num_bins
        
        R_noisy_onbin = stab(R_noisy(:, :, f), theta, num_channels);
        R_noise_onbin = stab(R_noise(:, :, f), theta, num_channels);
       
        R_noisy_inv = inv(R_noisy_onbin);
        R_noise_inv = inv(R_noise_onbin);
        R_noisy_accu = zeros(num_channels, num_channels);
        R_noise_accu = zeros(num_channels, num_channels);
        
        for t = 1: num_frames
            corre   = yyh(:, :, t, f);
            obs     = specs(:, t, f);
            
            % update lambda
            k_noise = obs' * (R_noise_inv / phi_noise(t, f)) * obs;
            det_noise = det(phi_noise(t, f) * R_noise_onbin) * pi;
            % +theta: avoid NAN
            p_noise(t, f) = real(exp(-k_noise) / det_noise) + theta;

            k_noisy = obs' * (R_noisy_inv / phi_noisy(t, f)) * obs;
            det_noisy = det(phi_noisy(t, f) * R_noisy_onbin) * pi;
            p_noisy(t, f) = real(exp(-k_noisy) / det_noisy) + theta;

            lambda_noise(t, f) = p_noise(t, f) / (p_noise(t, f) + p_noisy(t, f));
            lambda_noisy(t, f) = p_noisy(t, f) / (p_noise(t, f) + p_noisy(t, f));
            
            % update phi
            phi_noise(t, f) = real(trace(corre * R_noise_inv) / num_channels);
            phi_noisy(t, f) = real(trace(corre * R_noisy_inv) / num_channels);
            
            % accu R
            R_noise_accu = R_noise_accu + lambda_noise(t, f) / phi_noise(t, f) * corre;
            R_noisy_accu = R_noisy_accu + lambda_noisy(t, f) / phi_noisy(t, f) * corre;
        end
        % update R
        R_noise(:, :, f) = R_noise_accu / sum(lambda_noise(:, f));
        R_noisy(:, :, f) = R_noisy_accu / sum(lambda_noisy(:, f));
        
    end
    % Q = sum(sum(lambda_noise .* log(p_noise) + lambda_noisy .* log(p_noisy))) / (num_frames * num_bins);
    Qn = sum(sum(lambda_noise .* log(p_noise))) / (num_frames * num_bins);
    Qx = sum(sum(lambda_noisy .* log(p_noisy))) / (num_frames * num_bins);
    fprintf('--- iter = %2d, Q = %.4f + %.4f = %.4f\n', iter, Qn, Qx, Qn + Qx);
end

% save(['parm.mat'], 'lambda_noise');

R_xn = R_noisy;
% get Rn, reference to eq.4
R_n = zeros(num_channels, num_channels, num_bins);
for f = 1: num_bins
    for t = 1: num_frames
        R_n(:, :, f) = R_n(:, :, f) + lambda_noise(t, f) * yyh(:, :, t, f);
    end
    R_n(:, :, f) = R_n(:, :, f) / sum(lambda_noise(:, f));
end

R_x = R_xn - R_n;

% apply MVDR beamforming
specs_enhan = zeros(num_frames, num_bins);

for f = 1: num_bins
    % using Rx to estimate steer vector
    [vector, value] = eig(R_x(:, :, f));
    steer_vector = vector(:, 1);
    
    if rcond(R_n(:, :, f)) < theta
        R_n(:, :, f) = R_n(:, :, f) + theta * eye(num_channels);
        % fprintf('WARNING: ILL-CONDITION\n');
    end
    
    % feed Rn into MVDR
    % Rn_inv = inv(R_n(:, :, f));
    % w: M x 1
    % w = Rn_inv * steer_vector / (steer_vector' * Rn_inv * steer_vector);
    numerator = R_n(:, :, f) \ steer_vector;
    w = numerator / (steer_vector' * numerator);
    % specs M x T x F
    specs_enhan(:, f) = w' * specs(:, :, f);
end

% reconstruction
frames_enhan = irfft(specs_enhan, fft_length, 2);
% size(frames_enhan)
signal_enhan = overlapadd(frames_enhan(:, 1: frame_length), hanning_wnd, frame_shift);
% signal_enhan=signal_enhan ./ norm(signal_enhan, inf);
% audiowrite([ 'output.wav'], signal_enhan ./ norm(signal_enhan, inf), 16000);



function mat = stab(mat, theta, num_channels)
    d = 10 .^ (-6: 1: -1);
    for i = 1: 6
        if rcond(mat) > theta
            break;
        end
        mat = mat + d(i) * eye(num_channels);
    end
end
end
