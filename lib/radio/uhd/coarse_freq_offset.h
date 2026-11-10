#ifndef INCLUDED_FREQ_SHIFT_H
#define INCLUDED_FREQ_SHIFT_H

#include <iostream>
#include <vector>
#include <complex>
#include <cmath>
#include <cstdint>

// Origin: frequency shifter from the OAI UHD channel emulator (coarse_freq_offset), reused unchanged in OCUDU's
// UHD driver for NTN Doppler emulation. Changes: includes, member initialisation, guard against a zero step count.

/*!
 * \brief Class for coarse freq offset compensation. Initially a very hacky
 * way to do this by empirically estimating the offset which is expected to be
 * fixed (doppler will be offset from the ground)
 */

class Coarse_Freq_Offset
{
public:
    Coarse_Freq_Offset(const double frequency, const double sampling_frequency);

    ~Coarse_Freq_Offset();

    void set_freq(float angle_rate, float n_of_steps);
    void freq_shift(std::complex<int16_t> *input_items,
                                    int nsamp);

private:
    double m_sampling_freq;
    uint32_t m_phase;
    int32_t m_phase_inc;

    int32_t want_to_be_m_phase_inc;
    double what_we_have_m_phase_inc;
    float m_phase_inc_step;
    double m_steps;
    double m_lastrun;

  	double m_frequency;

    static constexpr int WORDBITS = 32;
    static constexpr int NBITS = 10;
    static const constexpr float TAU = 2 * M_PI;
    static const constexpr float TWO_TO_THE_31 = 2147483648.0;
    static const float m_sine_table[1 << NBITS][2];

    double CosineInterpolate(
    double y1,double y2,
    float mu)
    {
    double mu2;

    mu2 = (1-cos(float_to_fixed(mu*M_PI)))/2;
    return(y1*(1-mu2)+y2*mu2);
    }

    void step() { m_phase += static_cast<int32_t>(what_we_have_m_phase_inc); 
    what_we_have_m_phase_inc = CosineInterpolate(m_lastrun,want_to_be_m_phase_inc,(m_phase_inc_step*m_steps));
    m_steps++;
    }
    
    float sin(int32_t x);
    float cos(int32_t x);

	// angle_rate is in radians / step
	static int32_t float_to_fixed(float x);
};

#endif /* INCLUDED_FREQ_SHIFT_H */
