#include <p16f1619.inc>
#define FOSC D'32000000'
#define  I2CClock    D'400000'           ; define I2C bite rate
;;#define  I2CClock    D'10000'           ; define I2C bite rate
#define  ClockValue  (((FOSC/I2CClock)/4) -1) ; 
       ; general purpose memory usage:
    cblock 0x72                 ; shared memory accessible from all banks
    i2c_TOSH
    i2c_TOSL
    endc

 
I2c_VAR        UDATA	0x220   ; accessible from SSP register bank!
i2c_callback	RES	2
i2c_flags	RES	1
i2c_slave       RES	1               ;
i2c_count	RES	1
i2c_reserved	RES	0x0a
i2c_buf		RES	32

I2c CODE			; let linker place this

    global I2c_Init, I2c_Test, I2c_IRQ
    extern UART_Put
I2c_Init:
    banksel SSP1ADD		; select SFR bank
    movlw   ClockValue		; read selected baud rate 
    movwf   SSP1ADD		; initialize I2C baud rate
    bcf     SSP1STAT,6		; select I2C input levels
    bcf     SSP1STAT,7		; enable slew rate
    
    banksel ANSELB
    movlw   0x00
    movwf   ANSELB		; B4 and B6 must be digital

    banksel TRISB
    bsf	    TRISB,6		; SCL must be configured as input
    bsf	    TRISB,4		; SDA must be configured as input

    banksel RB6PPS
    movlw   0x10
    movwf   RB6PPS		; SCL output to go to RB6
    movlw   0x11
    movwf   RB4PPS		; SDA output to go to RB4
    
    banksel SSPCLKPPS
    movlw   0x0E
    movwf   SSPCLKPPS		; SCL input comes from RB6
    movlw   0x0C
    movwf   SSPDATPPS		; SDA input comes from RB4

    banksel SSP1CON1
    movlw   b'00101000'
    movwf   SSP1CON1		; Master mode, SSP enable
; The followng call is just a long-stop in-case an i2c interrupt happens
; before we expect it. In that case the following return is harmless.
    call    OnNext_I2c_IRQ
    return

OnNext_I2c_IRQ:
    banksel TOSL
    movf	TOSL,w
    movwf	i2c_TOSL
    movf	TOSH,w
    movwf	i2c_TOSH
    decf	STKPTR
    banksel PIE1		; now our 'vector' is written it is safge to allow
    bsf	    PIE1,SSP1IF		; the next interrupt to arrive.
    banksel SSP1CON
    return

I2c_IRQ:
    banksel PIE1
    btfss   PIE1,SSP1IE		; test is interrupt is enabled
    return
    ;;; goto	test_buscoll   ; no, so test for Bus Collision Int
    banksel PIR1
    btfss   PIR1,SSP1IF		; test for SSP H/W flag
    return
    bcf	    PIR1,SSP1IF		; clear SSP H/W flag
    banksel PIE1		; we must disable interrupts to prevent the NEXT
    bcf	    PIE1,SSP1IF		; interrpt from occurring before our context is set
    movf   i2c_TOSH,w
    movwf  PCLATH
    movf   i2c_TOSL,w
    banksel SSP1BUF	        ; actual handling code will usually need this bank;
    movwf  PCL			; branch to context-dependent handler


I2c_Xfer:    
    banksel SSP1CON2		; select SFR bank
    btfsc   SSP1STAT,R_NOT_W	; transmit in progress?
    goto    $-1
    movf    SSP1CON2,w
    andlw   0x1F		; mask out non-status bits
    btfss   STATUS,Z
    goto    $-3
    bcf	    SSP1CON2,ACKDT	; set ACK ton normal state
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
write_next:
    decf    i2c_count,f
    btfsc   i2c_count,7
    bra	    writing_done
    movf    i2c_buf,w
    movwf   SSP1BUF		; write the data byte
    call    OnNext_I2c_IRQ	; proceed when the data byte has been written
    bra	    write_next

straight_read:
    bsf	    SSP1CON2,RCEN	; enable receive
    call    OnNext_I2c_IRQ	; must wait for slave to pulse out data byte
    movf    SSP1BUF,w
    movwf   i2c_buf
    decf    i2c_count,f		; decrement to determine to ACK/NACK
    btfsc   STATUS,Z
    bra	    DoneLastRead
    bcf	    SSP1CON2,ACKDT	; must ACK to encourage slave to keep sending.
    bsf     SSP1CON2,ACKEN	; initiate acknowledge sequence
    call    OnNext_I2c_IRQ	; proceed when ACK bit has been sent
    bra	    straight_read	; now we must invite the next byte.
    
DoneLastRead:
    bsf	    SSP1CON2,ACKDT	; must NACK to make slave get off the bus!
    bsf     SSP1CON2,ACKEN	; initiate acknowledge sequence
    call    OnNext_I2c_IRQ	; proceed when NACK bit has been sent
				; follow through to generate stop condition
writing_done:
    clrf    i2c_count	    	; we let this go negative earlier for easy test.
early_stop_cond:
stop_cond:
    bsf	    SSP1CON2,PEN	; generate stop condition
    call    OnNext_I2c_IRQ	; proceed when stop condition has been given.

    bsf    i2c_flags,7		; = operation completed
    call    OnNext_I2c_IRQ
    return

I2c_sync_Xfer:
    clrf    i2c_flags
    call    I2c_Xfer
I2c_wait:
    banksel SSP1CON2		; select SFR bank
    btfss   i2c_flags,7		; transfer still in progress?
    goto    $-1
    return
    
I2c_Test:
    banksel SSP1CON2		; select SFR bank
    clrf    i2c_buf
I2c_write_loop:
    decf    i2c_buf,f
    movlw   0x70		; prepare to access i2c device PCF8574A 0111 000 
    movwf   i2c_slave		; this is an 8-bit address!
    movlw   1
    call    I2c_sync_Xfer
    ;goto    I2c_write_loop
    incf    i2c_slave,f		; now set the R bit!
I2c_read_loop:
    banksel SSP1CON2		; select SFR bank    
    incf    i2c_count,f		; count will have gone to zero.
    call    I2c_sync_Xfer
;    btfsc   i2c_buf,7		; look for IO pin 7 being pulled down
;    goto    I2c_read_loop
;    nop				; set breakpoint here for test!
    movf    i2c_buf,w
    call    UART_Put
    goto    I2c_read_loop
    END
