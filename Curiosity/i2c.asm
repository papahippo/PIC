#include <p16f1619.inc>
#define FOSC D'32000000'
#define  I2CClock    D'400000'           ; define I2C bite rate
#define  ClockValue400  (((FOSC/I2CClock)/4) -1) ; 
       ; general purpose memory usage:
    cblock 0x72                 ; shared memory accessible from all banks
    i2c_IRQ_TOSL
    i2c_IRQ_TOSH
    endc

 
I2c_VAR        UDATA	0x220   ; accessible from SSP register bank!
i2c_flags	    RES	1	; public parameter, also used internally
i2c_slave	    RES	1       ; public parameter; n.b. 8-bit address + R/W
i2c_count	    RES	1	; public parameter; buffer size to read/write
i2c_callbackL	    RES	1	; public parameters = address of code following 
i2c_callbackH	    RES	1	;      call to I2c_Xfer
i2c_active_slave    RES 1	; private parameter to deteremine special cases
i2c_reserved	    RES	d'10'
i2c_buf		    RES	32	; temporary! buffer access code not yet written.

 I2c CODE			; let linker place this

    global I2c_Init, I2c_Test, I2c_IRQ, I2c_Xfer
    
    extern UART_Put
 
I2c_Init_400Khz:
    movlw   ClockValue400	; read selected bit rate 
I2c_Init:
    banksel SSP1ADD		; select SFR bank
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
    movwf	i2c_IRQ_TOSL
    movf	TOSH,w
    movwf	i2c_IRQ_TOSH
    decf	STKPTR
    banksel PIE1		; now our 'vector' is written it is safe to allow
    bsf	    PIE1,SSP1IF		; the next interrupt to arrive.
    banksel SSP1CON
    return

I2c_IRQ:
    banksel PIE1
    btfss   PIE1,SSP1IE		; test if interrupt is enabled
    return
    ;;; goto	test_buscoll   ; no, so test for Bus Collision Int
    banksel PIR1
    btfss   PIR1,SSP1IF		; test for SSP H/W flag
    return			; no I2C IRQ so return to generic IRQ code
    bcf	    PIR1,SSP1IF		; clear SSP H/W flag
; we disable SSP (hence I2c) interrupts during the handler; this is necessary to
; make our dispaching code safe but of course means a little extra IRQ latency.
    banksel PIE1
    bcf	    PIE1,SSP1IF		; interrpt from occurring before our context is set
    movf   i2c_IRQ_TOSH,w	; we now dispatch (tricky goto!) the code address
    movwf  PCLATH		; set by the last call to 'OnNext_I2c_IRQ'.
    movf   i2c_IRQ_TOSL,w
    banksel SSP1BUF	        ; actual handling code will usually need this bank;
    movwf  PCL			; branch to context-dependent handler

; all I2C reads and writes go (directly or indirectly) via I2c_Xfer.
; !! full parameter description to be added!!
; i2c_flags: should be zero before initiating an I2c transfer from a (presumed)
; i2c-bus-idle situation. The driver sets bit 0 when starting the transfer and 
; clears it when the i2c bus becomes free after the complete chain of 1 or more
; i2c transfers.
; Note, however, that the function 'I2c_Xfer' returns via the user's callback
; function before issuing the stop condition and - in the case of a read
; operation - before ACKing or NACKing the last received byte. A second call to
; I2c_Xfer is needed to [perform the last ACK/NACK and] issue the stop condition.
; This complication is 'hidden' when using the simple 'I2c_sync_Xfer' function
; (see below). Its purpose is to facilitate:
;   - i2c 'repeated start' implementation.
;   - continuous input or ouput of more bytes than are contiguously available
;     in the PIC memory.
;   - other chained operations; one can compose a kind of 'i2c management thread'
;     without the need for any OS. This must be used wisely of course like all
;     good things!
I2c_Xfer:    
    banksel TOSL
    movf    TOSL,w		; read lower byte of 'return' address
    banksel SSP1CON2		; select SFR bank
    movwf   i2c_callbackL	; save lower byte of 'return' address
    banksel TOSH
    movf    TOSH,w		; read upper byte of 'return' address
    decf    STKPTR
    banksel SSP1CON2		; select SFR bank
    movwf   i2c_callbackH	; save upper byte of 'return' address
    btfss   i2c_flags,0		; is this a brand new operation?
  bra	    new_start		; YES:-> start by giving start condition.
    movwf   i2c_active_slave
    subwf   i2c_slave,f
    btfsc   STATUS,Z
    bra	    more_of_same
    andlw   1
    btfss   STATUS,Z
    bra	    
new_start:
    bsf     i2c_flags,0		; 1 => Xfer in progress
    btfsc   SSP1STAT,R_NOT_W	; transmit in progress?
    goto    $-1
    movf    SSP1CON2,w
    andlw   0x1F		; mask out non-status bits
    btfss   STATUS,Z
    goto    $-3
    bcf	    SSP1CON2,ACKDT	; set ACK ton normal state
    bsf     SSP1CON2,SEN	; initiate I2C bus start condition
    call    OnNext_I2c_IRQ

; The first interrupt after we cause the start condition gets to here:
    movf    i2c_slave,w		; bit 0 = R/W has already been manipulated
    movwf   SSP1BUF		; write I2C address of our slave to i2c_bus.
; We privately remember the slave address and R/W bit so that, following a
; a callback, we can correctly identify repeated start and other conditions.
    movwf   i2c_active_slave	; save a copy
    call    OnNext_I2c_IRQ	; proceed when slave address has been written
;The first interrupt after we write the slave address gets to here:
    btfsc   SSP1CON2,ACKSTAT	; did our presumed slave acknowledge?
    bra	    IO_error		; no? waste no more time. get off i2c bus asap.
    btfsc   i2c_slave,0		; what must we do (first)? read or write?
    bra	    straight_read	; immediate read (e.g. no sub-address to write).
write_next:
    decf    i2c_count,f
    btfsc   i2c_count,7
    bra	    IO_done
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
IO_done:
    clrf    i2c_count	    	; we let this go negative earlier for easy test.
    bra	    IO_end
IO_error:
    bsf     i2c_flags,1		; 3 => error, but not yet stopped
IO_end:
    movf   i2c_callbackH,w
    movwf  PCLATH
    movf   i2c_callbackL,w
    movwf  PCL			; branch to context-dependent handler

Give_stop_cond:
    bsf	    SSP1CON2,PEN	; generate stop condition
    call    OnNext_I2c_IRQ	; proceed when stop condition has been given.
    bcf     i2c_flags,0		; = operation completed
    return

I2c_Xfer_then_stop:
    call    I2c_Xfer		; follows through some interrupts later!
    call    I2c_Xfer		; follows through some interrupts later!
    return


I2c_sync_Xfer:
    call    I2c_Xfer_then_stop	; ordinary call (for a change!)
I2c_wait:
    banksel SSP1CON2		; select SFR bank
    btfsc   i2c_flags,0		; transfer still in progress?
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
    bsf    i2c_slave,0		; now set the R bit!
I2c_read_loop:
    banksel SSP1CON2		; select SFR bank    
    incf    i2c_count,f		; count will have gone to zero.
    call    I2c_sync_Xfer
    movf    i2c_buf,w
    call    UART_Put
    goto    I2c_read_loop
    END
