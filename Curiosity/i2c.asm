#include <p16f1619.inc>
#define FOSC 32000000
#define  I2CClock    D'400000'           ; define I2C bite rate
;;#define  I2CClock    D'10000'           ; define I2C bite rate
#define  ClockValue  (((FOSC/I2CClock)/4) -1) ; 
 

I2c CODE                ; let linker place this

    global I2c_Init, I2c_Test, I2c_IRQ
I2c_Init:
    banksel SSP1ADD     ; select SFR bank
    movlw   ClockValue  ; read selected baud rate 
    movwf   SSP1ADD     ; initialize I2C baud rate
    bcf     SSP1STAT,6  ; select I2C input levels
    bcf     SSP1STAT,7  ; enable slew rate
    ;movlw   0x80
    ;movwf   SSP1STAT
    
    banksel ANSELB
    movlw   0x00
    movwf   ANSELB
    ;bcf	    ANSELB,4	; SCL digital not analogue
    banksel TRISB
    bsf	    TRISB,6	; SCL must be configured as input
    bsf	    TRISB,4	; SDA must be configured as input
if 1
    banksel RB6PPS
    movlw   0x10
    movwf   RB6PPS	; SCL output to go to RB6
    movlw   0x11
    movwf   RB4PPS	; SDA output to go to RB4
    
    banksel SSPCLKPPS
    movlw   0x0E
    movwf   SSPCLKPPS	; SCL input comes from RB6
    movlw   0x0C
    movwf   SSPDATPPS	; SDA input comes from RB4
endif
    banksel SSP1CON1
    movlw   b'00101000'
    movwf   SSP1CON1    ; Master mode, SSP enable
    ;movlw	0x80
    ;movwf   SSP1STAT
    banksel PIE1
    bsf	PIE1,SSP1IE     ; enable SSP interrupt

    return

I2c_IRQ:
    movlw  0x55
    banksel SSP1BUF     ; select SFR bank
    movwf   SSP1BUF     ; initiate I2C bus write condition
    return
I2c_Test:
    banksel SSP1CON2      ; select SFR bank
    btfsc   SSP1STAT,R_NOT_W  ; transmit in progress?
    goto    $-1
    movf    SSP1CON2,w
    andlw   0x1F	  ; maks out non-status bits
    btfss   STATUS,Z
    goto    $-3
    bsf     SSP1CON2,SEN  ; initiate I2C bus start condition
    btfsc   SSP1CON2,SEN  ; test start bit state
    goto    $-1		 ; module busy
; so wait
   ; movlw  0x55
   ; banksel SSP1BUF     ; select SFR bank
   ; movwf   SSP1BUF     ; initiate I2C bus write condition
    return                           ; 
     
    END