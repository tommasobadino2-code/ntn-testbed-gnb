#include "coarse_freq_offset.h"
#include <x86intrin.h>
#include <algorithm>

Coarse_Freq_Offset::Coarse_Freq_Offset(const double frequency, const double sampling_frequency)
	: m_sampling_freq(sampling_frequency),
	  m_phase(0),
	  m_phase_inc(0),
	  want_to_be_m_phase_inc(0),
	  what_we_have_m_phase_inc(0),
	  m_phase_inc_step(0),
	  m_steps(0),
      m_lastrun(0),
	  m_frequency(frequency)
{
	set_freq(2.0f * M_PI * frequency / m_sampling_freq, 266400.0);
}

Coarse_Freq_Offset::~Coarse_Freq_Offset() {}

//angle_rate is in radians / step
void Coarse_Freq_Offset::set_freq(float angle_rate, float n_of_steps)
{ 
        //printf("diff %lf\n", double((double)m_phase_inc-(double)float_to_fixed(angle_rate))/(double)RXBUFFER);
        // m_lastrun = what_we_have_m_phase_inc;
        // m_phase_inc_step =  (float_to_fixed(angle_rate)-(m_lastrun))/n_of_steps;
		// m_phase_inc = float_to_fixed(angle_rate);
        // want_to_be_m_phase_inc = float_to_fixed(angle_rate);        
        m_steps = 0;
        m_phase_inc_step = 1.0 / std::max(n_of_steps, 1.0f);
        m_lastrun = what_we_have_m_phase_inc;
        want_to_be_m_phase_inc = float_to_fixed(angle_rate); 
}

int32_t Coarse_Freq_Offset::float_to_fixed(float x)
{
		// Fold x into -PI to PI.
		int d = (int)std::floor(x / TAU + 0.5);
		x -= d * TAU;
		// And convert to an integer.
		return (int32_t)((float)x * TWO_TO_THE_31 / M_PI);
}

const float Coarse_Freq_Offset::m_sine_table[1 << NBITS][2] = {
#include "sine_table.h"
};

float Coarse_Freq_Offset::sin(int32_t x)
{
    uint32_t ux = x;
    int index = ux >> (WORDBITS - NBITS);
    return m_sine_table[index][0] * (ux >> 1) + m_sine_table[index][1];
}

float Coarse_Freq_Offset::cos(int32_t x)
{
    uint32_t ux = x + 0x40000000;
    int index = ux >> (WORDBITS - NBITS);
    return m_sine_table[index][0] * (ux >> 1) + m_sine_table[index][1];
}

void Coarse_Freq_Offset::freq_shift(std::complex<int16_t> *input_items, int nsamp)
{
    int i = 0;
    
    // Pre-calculate the phase increment for vectorization
    int32_t phase_inc = static_cast<int32_t>(what_we_have_m_phase_inc);
    
    // Process 4 samples at a time using SIMD
    for (; i <= nsamp - 4; i += 4) {
        // Calculate 4 consecutive phase values
        uint32_t phase0 = m_phase;
        uint32_t phase1 = m_phase + phase_inc;
        uint32_t phase2 = m_phase + 2 * phase_inc;
        uint32_t phase3 = m_phase + 3 * phase_inc;
        
        // Calculate sin/cos for all 4 phases
        float cos0 = cos(phase0), sin0 = sin(phase0);
        float cos1 = cos(phase1), sin1 = sin(phase1);
        float cos2 = cos(phase2), sin2 = sin(phase2);
        float cos3 = cos(phase3), sin3 = sin(phase3);
        
        // Load input data into SIMD registers
        // Pack real parts: [real0, real1, real2, real3]
        __m128 input_real = _mm_set_ps(
            static_cast<float>(input_items[i+3].real()),
            static_cast<float>(input_items[i+2].real()),
            static_cast<float>(input_items[i+1].real()),
            static_cast<float>(input_items[i+0].real())
        );
        
        // Pack imaginary parts: [imag0, imag1, imag2, imag3]
        __m128 input_imag = _mm_set_ps(
            static_cast<float>(input_items[i+3].imag()),
            static_cast<float>(input_items[i+2].imag()),
            static_cast<float>(input_items[i+1].imag()),
            static_cast<float>(input_items[i+0].imag())
        );
        
        // Pack cosine values: [cos0, cos1, cos2, cos3]
        __m128 cos_vals = _mm_set_ps(cos3, cos2, cos1, cos0);
        
        // Pack sine values: [sin0, sin1, sin2, sin3]
        __m128 sin_vals = _mm_set_ps(sin3, sin2, sin1, sin0);
        
        // Complex multiplication: (a + bi) * (c + di) = (ac - bd) + (ad + bc)i
        // Real part: real_in * cos - imag_in * sin
        __m128 real_cos = _mm_mul_ps(input_real, cos_vals);
        __m128 imag_sin = _mm_mul_ps(input_imag, sin_vals);
        __m128 result_real = _mm_sub_ps(real_cos, imag_sin);
        
        // Imaginary part: real_in * sin + imag_in * cos
        __m128 real_sin = _mm_mul_ps(input_real, sin_vals);
        __m128 imag_cos = _mm_mul_ps(input_imag, cos_vals);
        __m128 result_imag = _mm_add_ps(real_sin, imag_cos);
        
        // Extract results and convert back to int16_t
        float real_results[4], imag_results[4];
        _mm_storeu_ps(real_results, result_real);
        _mm_storeu_ps(imag_results, result_imag);
        
        // Store results back to input array
        input_items[i+0] = std::complex<int16_t>(
            static_cast<int16_t>(real_results[0]), 
            static_cast<int16_t>(imag_results[0])
        );
        input_items[i+1] = std::complex<int16_t>(
            static_cast<int16_t>(real_results[1]), 
            static_cast<int16_t>(imag_results[1])
        );
        input_items[i+2] = std::complex<int16_t>(
            static_cast<int16_t>(real_results[2]), 
            static_cast<int16_t>(imag_results[2])
        );
        input_items[i+3] = std::complex<int16_t>(
            static_cast<int16_t>(real_results[3]), 
            static_cast<int16_t>(imag_results[3])
        );
        
        // Update phase by 4 steps
        m_phase += 4 * phase_inc;
        
        // Update step tracking (simplified for vectorization)
        m_steps += 4;
        what_we_have_m_phase_inc = CosineInterpolate(m_lastrun, want_to_be_m_phase_inc, 
                                                    m_phase_inc_step * m_steps);
    }
    
    // Handle remaining samples (0-3 samples) with scalar code
    for (; i < nsamp; i++) {
        float cos_val = cos(m_phase);
        float sin_val = sin(m_phase);
        float real_in = static_cast<float>(input_items[i].real());
        float imag_in = static_cast<float>(input_items[i].imag());

        int16_t re = static_cast<int16_t>(real_in * cos_val - imag_in * sin_val);
        int16_t im = static_cast<int16_t>(real_in * sin_val + imag_in * cos_val);

        input_items[i] = std::complex<int16_t>(re, im);
        
        // Update phase and step
        m_phase += static_cast<int32_t>(what_we_have_m_phase_inc);
        m_steps++;
        what_we_have_m_phase_inc = CosineInterpolate(m_lastrun, want_to_be_m_phase_inc, 
                                                    m_phase_inc_step * m_steps);
    }
}
