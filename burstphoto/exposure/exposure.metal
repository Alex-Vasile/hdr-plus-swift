#include <metal_stdlib>
#include "../misc/constants.h"

using namespace metal;

/**
 Correction of underexposure with reinhard tone mapping operator.
 
 Inspired by https://www-old.cs.utah.edu/docs/techreports/2002/pdf/UUCS-02-001.pdf
 */
kernel void correct_exposure(texture2d<float, access::read> final_texture_blurred [[texture(0)]],
                             texture2d<float, access::read_write> final_texture [[texture(1)]],
                             constant int& exposure_bias         [[buffer(0)]],
                             constant int& target_exposure       [[buffer(1)]],
                             constant int& mosaic_pattern_width  [[buffer(2)]],
                             constant float& white_level         [[buffer(3)]],
                             constant float& color_factor_mean   [[buffer(4)]],
                             constant float& black_level_mean    [[buffer(5)]],
                             constant float& black_level_min     [[buffer(6)]],
                             constant float* black_levels_mean_buffer   [[buffer(7)]],
                             constant float* max_texture_buffer         [[buffer(8)]],
                             uint2 gid [[thread_position_in_grid]]) {
    // load args
    float const black_level = black_levels_mean_buffer[mosaic_pattern_width*(gid.y % mosaic_pattern_width) + (gid.x % mosaic_pattern_width)];
       
    // calculate gain for intensity correction
    float const correction_stops = float((target_exposure-exposure_bias)/100.0f);
    
    // calculate linear gain to get close to full range of intensity values before tone mapping operator is applied
    float linear_gain = (white_level-black_level_min)/(max_texture_buffer[0]-black_level_min);
    linear_gain = clamp(0.9f*linear_gain, 1.0f, 16.0f);
    
    // the gain is limited to 4.0 stops and it is slightly damped for values > 2.0 stops
    float gain_stops = clamp(correction_stops-log2(linear_gain), 0.0f, 4.0f);
    float const gain0 = pow(2.0f, gain_stops-0.05f*max(0.0f, gain_stops-1.5f));
    float const gain1 = pow(2.0f, gain_stops/1.4f);
    
    // extract pixel value
    float pixel_value = final_texture.read(gid).r;
    
    // subtract black level and rescale intensity to range from 0 to 1
    float const rescale_factor = (white_level - black_level_min);
    pixel_value = clamp((pixel_value-black_level)/rescale_factor, 0.0f, 1.0f);
   
    // use luminance estimated as the binomial weighted mean pixel value in a 3x3 window around the main pixel
    // apply correction with color factors to reduce clipping of the green color channel
    float luminance_before = final_texture_blurred.read(gid).r;
    luminance_before = clamp((luminance_before-black_level_mean)/(rescale_factor*color_factor_mean), 1e-12, 1.0f);
    
    // apply gains
    float luminance_after0 = linear_gain * gain0 * luminance_before;
    float luminance_after1 = linear_gain * gain1 * luminance_before;
        
    // apply tone mappting operator specified in equation (4) in https://www-old.cs.utah.edu/docs/techreports/2002/pdf/UUCS-02-001.pdf
    // the operator is linear in the shadows and midtones while protecting the highlights
    luminance_after0 = luminance_after0 * (1.0f+luminance_after0/(gain0*gain0)) / (1.0f+luminance_after0);
    
    // apply a modified tone mapping operator, which better protects the highlights
    float const luminance_max = gain1 * (0.4f+gain1/(gain1*gain1)) / (0.4f+gain1);
    luminance_after1 = luminance_after1 * (0.4f+luminance_after1/(gain1*gain1)) / ((0.4f+luminance_after1)*luminance_max);
    
    // calculate weight for blending the two tone mapping curves dependent on the magnitude of the gain
    float const weight = clamp(gain_stops*0.25f, 0.0f, 1.0f);
        
    // apply scaling derived from luminance values and return to original intensity scale
    pixel_value = pixel_value * ((1.0f-weight)*luminance_after0 + weight*luminance_after1)/luminance_before * rescale_factor + black_level;
    pixel_value = clamp(pixel_value, 0.0f, float(UINT16_MAX_VAL));

    final_texture.write(pixel_value, gid);
}


/**
 Correction of underexposure with simple linear scaling
 */
kernel void correct_exposure_linear(texture2d<float, access::read_write> final_texture [[texture(0)]],
                                    constant float& white_level [[buffer(0)]],
                                    constant float& linear_gain [[buffer(1)]],
                                    constant int& mosaic_pattern_width [[buffer(2)]],
                                    constant float& black_level_min     [[buffer(3)]],
                                    constant float* black_levels_mean_buffer [[buffer(4)]],
                                    constant float* max_texture_buffer       [[buffer(5)]],
                                    
                                    uint2 gid [[thread_position_in_grid]]) {
   
    // load args
    float const black_level = black_levels_mean_buffer[mosaic_pattern_width*(gid.y % mosaic_pattern_width) + (gid.x % mosaic_pattern_width)];
    
    // calculate correction factor to get close to full range of intensity values
    float corr_factor = (white_level - black_level_min)/(max_texture_buffer[0] - black_level_min);
    corr_factor = clamp(0.9f*corr_factor, 1.0f, 16.0f);
    // use maximum of specified linear gain and correction factor
    corr_factor = max(linear_gain, corr_factor);
       
    // extract pixel value
    float pixel_value = final_texture.read(gid).r;
    
    // correct exposure
    pixel_value = max(0.0f, pixel_value-black_level)*corr_factor + black_level;
    pixel_value = clamp(pixel_value, 0.0f, float(UINT16_MAX_VAL));

    final_texture.write(pixel_value, gid);
}


kernel void max_x(texture1d<float, access::read> in_texture [[texture(0)]],
                  device float *out_buffer [[buffer(0)]],
                  constant int& width [[buffer(1)]],
                  uint gid [[thread_position_in_grid]]) {
    float max_value = 0;
    
    for (int x = 0; x < width; x++) {
        max_value = max(max_value, in_texture.read(uint(x)).r);
    }

    out_buffer[0] = max_value;
}


kernel void max_y(texture2d<float, access::read> in_texture [[texture(0)]],
                  texture1d<float, access::write> out_texture [[texture(1)]],
                  uint gid [[thread_position_in_grid]]) {
    uint x = gid;
    int texture_height = in_texture.get_height();
    float max_value = 0;
    
    for (int y = 0; y < texture_height; y++) {
        max_value = max(max_value, in_texture.read(uint2(x, y)).r);
    }

    out_texture.write(max_value, x);
}
