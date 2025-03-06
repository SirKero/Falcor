
#define IMPORTANCE_MAX_ATOMIC_WEIGHT 64
#define MIN_OPACITY 1e-7
#define MAX_LOWEST_LEVEL_IMPORTANCE IMPORTANCE_MAX_ATOMIC_WEIGHT * 256
//Compaire value for the optional mask. Value can be changed to 0.004 (~ 1./255) to delay 1 frame or 0.008 (~ 2./255) to delay 2 frames
#define TRANSPARENCY_MASK_COMPAIRE_VALUE 0.0 //0.004 0.008
