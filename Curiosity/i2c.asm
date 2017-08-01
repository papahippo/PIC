#include <p16f1619.inc>
#define FOSC D'32000000'
#define  I2CClock    D'400000'           ; define I2C bite rate
;;#define  I2CClock    D'10000'           ; define I2C bite rate
#define  ClockValue  (((FOSC/I2CClock)/4) -1) ; 
       ; general purpose memory usage:
    cblock 0x72                         ;shared memory location that is accessible from all banks
    i2c_TOSH
    i2c_TOSL
    endc

 
I2c_VAR        UDATA	0x220             ; accessible from SSP register bank!
i2c_callback	RES	2
i2c_status	RES	1
i2c_slave       RES	1               ;
i2c_write_count RES	1
i2c_read_count	RES	1
i2c_reserved	RES	0x0a
i2c_buf		RES	32

I2c CODE                ; let linker place this

    global I2c_Init, I2c_Test, I2c_IRQ

I2c_Init:
    banksel SSP1ADD     ; select SFR bank
    movlw   ClockValue  ; read selected baud rate 
    movwf   SSP1ADD     ; initialize I2C baud rate
    bcf     SSP1STAT,6  ; select I2C input levels
    bcf     SSP1STAT,7  ; enable slew rate
    
    banksel ANSELB
    movlw   0x00
    movwf   ANSELB

    banksel TRISB
    bsf	    TRISB,6	; SCL must be configured as input
    bsf	    TRISB,4	; SDA must be configured as input

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

    banksel SSP1CON1
    movlw   b'00101000'
    movwf   SSP1CON1    ; Master mode, SSP enable
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
    banksel PIE1	    ; now our 'vector' is written it is safge to allow
    bsf	    PIE1,SSP1IF	    ; the next interrupt to arrive.
    banksel SSP1CON
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
    banksel PIE1        ; we must disable interrupts to prevent the
    bcf	    PIE1,SSP1IF ; NEXT interrpt from occurring before our context is set
    movf   i2c_TOSH,w
    movwf  PCLATH
    movf   i2c_TOSL,w
    banksel SSP1BUF	; actual handling code will usually need this bank
    movwf  PCL		; branch to context-dependent handler


I2c_Xfer:    
    banksel SSP1CON2		; select SFR bank
    clrf    i2c_status		; = operation in progress 
    bcf	    i2c_slave,0		; correct if we're writing first...  but maybe ...
    movf    i2c_write_count,w	; ... there's no data writing to do
    btfsc   STATUS,Z
    bsf	    i2c_slave,0		; correct bit 0 for reading straightaway
    btfsc   SSP1STAT,R_NOT_W	; transmit in progress?
    goto    $-1
    movf    SSP1CON2,w
    andlw   0x1F		; mask out non-status bits
    btfss   STATUS,Z
    goto    $-3
    bsf     SSP1CON2,SEN	; initiate I2C bus start condition
    call    OnNext_I2c_IRQ

    ; first interrupt after setting start condition gets to here:
    movf    i2c_slave,w		; bit 0 = R/W has already been manipulated
    movwf   SSP1BUF		; initiate I2C bus write condition
    call    OnNext_I2c_IRQ	; proceed when slave address has been written

    ; interrupt after writing slave address gets to here:
    btfsc   SSP1CON2,ACKSTAT	; did our presumed slave acknowledge?
    bra	    early_stop_cond	; no? waste no more time. get off i2c bus asap.
    btfsc   i2c_slave,0		; what must we do (first)? read or write?
    bra	    straight_read	; immediate read (e.g. no sub-address to write).

; folowing code is 'stubbed' down to enforce a single byte to be written, so
; we can test the code on a simple PFC8574A before implementing tricky stuff!
    movf    i2c_buf,w
    movwf   SSP1BUF		; write the data byte
    call    OnNext_I2c_IRQ	; proceed when teh data byte has been written
; in this stubby code, we now just write a stop condition
    bra	    stop_cond

straight_read:
    ; not yet implemented!
early_stop_cond:
stop_cond:
    bsf	    SSP1CON2,PEN	; generate stop condition
    call    OnNext_I2c_IRQ	; proceed when stop condition has been given.

    incf    i2c_status,f	; 1 = operation completed
I2c_Ignore_IRQ:
    call    OnNext_I2c_IRQ	; don't expect more I2c interrupt but don't
    bra	    I2c_Ignore_IRQ

    
I2c_Test:
    banksel SSP1CON2		; select SFR bank
    clrf    i2c_buf
I2c_Test_loop:
    movlw   0x70	    ; prepare to access i2c device PCF8574A 0111 000 
    movwf   i2c_slave	    ; this is an 8-bit address!
    movlw   1
    movwf   i2c_write_count
    clrf    i2c_read_count    
    call    I2c_Xfer
    btfss   i2c_status,0	; transfer still lin progress?
    goto    $-1
    incf    i2c_buf,f
    goto    I2c_Test_loop

    END