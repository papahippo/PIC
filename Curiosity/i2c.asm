#include <p16f1619.inc>
#define FOSC 32000000
#define  I2CClock    D'400000'           ; define I2C bite rate
;;#define  I2CClock    D'10000'           ; define I2C bite rate
#define  ClockValue  (((FOSC/I2CClock)/4) -1) ; 
       ; general purpose memory usage:
    cblock 0x72                         ;shared memory location that is accessible from all banks
    i2c_TOSH
    i2c_TOSL
    endc

 
I2c_VAR        UDATA   0x220             ; accessible from SSP register bank!
my_slave       RES     1               ;

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
    ;banksel PIE1
    ;bsf    PIE1,SSP1IE     ; enable SSP interrupt
; The followng call is just a long-stop in-case an i2c interrupt happens
; before we expect it. In that case the following return is harmless.
    call    OnNext_I2c_IRQ
    return                         ; return from subroutine

OnNext_I2c_IRQ:
    banksel TOSL
    movf	TOSL,w
    movwf	i2c_TOSL
    movf	TOSH,w
    movwf	i2c_TOSH
    decf	STKPTR
    banksel PIE1
    bsf	    PIE1,SSP1IF
    return

I2c_IRQ:
    banksel PIE1
    btfss   PIE1,SSP1IE               ; test is interrupt is enabled
    return
    ;;; goto	test_buscoll             ; no, so test for Bus Collision Int
    banksel PIR1
    btfss   PIR1,SSP1IF               ; test for SSP H/W flag
    return
    bcf	    PIR1,SSP1IF               ; clear SSP H/W flag
    banksel PIE1
    bcf	    PIE1,SSP1IF
    movf   i2c_TOSH,w
    movwf  PCLATH
    movf   i2c_TOSL,w
    movwf  PCL


start_cond:    
    movwf   my_slave
    banksel SSP1CON2      ; select SFR bank
    btfsc   SSP1STAT,R_NOT_W  ; transmit in progress?
    goto    $-1
    movf    SSP1CON2,w
    andlw   0x1F	  ; maks out non-status bits
    btfss   STATUS,Z
    goto    $-3
    bsf     SSP1CON2,SEN  ; initiate I2C bus start condition
    ;btfsc   SSP1CON2,SEN  ; test start bit state
    ;goto    $-1		 ; module busy
temp_loop:
    call    OnNext_I2c_IRQ
; first interrupt after setting start condition gets to here:
    movf    my_slave,w
    banksel SSP1BUF     ; select SFR bank
    movwf   SSP1BUF     ; initiate I2C bus write condition
    bra	    temp_loop

I2c_Test:
    movlw   0x40	    ; prepare to write to i2c device PCF8574 0100 0000
    goto    start_cond
     
    END