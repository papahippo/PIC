#include <p16f1619.inc>
#define FOSC D'32000000'
#define  I2CClock    D'400000'           ; define I2C bite rate
#define  ClockValue400KHz  (((FOSC/I2CClock)/4) -1) ; 
       ; general purpose memory usage:
    cblock 0x72                 ; shared memory accessible from all banks
    i2c_IRQ_TOSL
    i2c_IRQ_TOSH
    endc

 
I2c_VAR        UDATA	0x220   ; accessible from SSP register bank!
i2c_flags	    RES	1	; public parameter, also used internally
i2c_slave	    RES	1       ; public parameter; n.b. 8-bit address + R/W
i2c_count	    RES	1	; passed in W! buffer size to read/write
i2c_callbackL	    RES	1	; public parameters = address of code following 
i2c_callbackH	    RES	1	;      call to I2c_Drive
i2c_active_slave    RES 1	; private parameter to deteremine special cases
i2c_reserved	    RES	d'10'
i2c_buf		    RES	32	; temporary! buffer access code not yet written.

I2c CODE			; let linker place this

    global  I2c_Init_400KHz, I2c_Init, I2c_IRQ, I2c_Drive, I2c_Use_Internal_Buffer
    global  I2c_Test, I2c_Probe
    
    extern UART_Get, UART_Put, UART_Print
 
I2c_Init_400KHz:
    movlw   ClockValue400KHz	; read selected bit rate 
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

    banksel LATB
    bsf	    LATB,6		; SCL must be configured as input
    bsf	    LATB,4		; SDA must be configured as input

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

I2c_Use_Internal_Buffer:
    banksel SSP1CON2		; select SFR bank
    movlw   high i2c_buf
    movwf   FSR1H
    movlw   low i2c_buf
    movwf   FSR1L
    return

OnNext_I2c_IRQ:
    banksel TOSL
    movf	TOSL,w
    movwf	i2c_IRQ_TOSL
    movf	TOSH,w
    movwf	i2c_IRQ_TOSH
    decf	STKPTR,f
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

; all I2C reads and writes go (directly or indirectly) via I2c_Drive.
; !! full parameter description to be added!!
; i2c_flags: should be zero before initiating an I2c transfer from a (presumed)
; i2c-bus-idle situation. The driver sets bit 0 when starting the transfer and 
; clears it when the i2c bus becomes free after the complete chain of 1 or more
; i2c transfers.
; Note, however, that the function 'I2c_Drive' returns via the user's callback
; function before issuing the stop condition and - in the case of a read
; operation - before ACKing or NACKing the last received byte. A second call to
; I2c_Drive is needed to [perform the last ACK/NACK and] issue the stop condition.
; This complication is 'hidden' when using the simple 'I2c_sync_Xfer' function
; (see below). Its purpose is to facilitate:
;   - i2c 'repeated start' implementation.
;   - continuous input or ouput of more bytes than are contiguously available
;     in the PIC memory.
;   - other chained operations; one can compose a kind of 'i2c management thread'
;     without the need for any OS. This must be used wisely of course like all
;     good things!
I2c_Drive:    
    banksel TOSL
    movf    TOSL,w		; read lower byte of 'return' address
    banksel SSP1CON2		; select SFR bank
    movwf   i2c_callbackL	; save lower byte of 'return' address
    banksel TOSH
    movf    TOSH,w		; read upper byte of 'return' address
    decf    STKPTR
    banksel SSP1CON2		; select SFR bank
    movwf   i2c_callbackH	; save upper byte of 'return' address
    btfsc   i2c_flags,0		; is this a brand new operation?
    bra	    resuming		

  ; Brand new I/O:-> start by giving start condition.
new_start:
    bsf     i2c_flags,0		; 1 => Xfer in progress
    btfsc   SSP1STAT,R_NOT_W	; transmit in progress?
    goto    $-1
    movf    SSP1CON2,w
    andlw   0x1F		; mask out non-status bits
    btfss   STATUS,Z
    goto    $-3
    bcf	    SSP1CON2,ACKDT	; set ACK to normal state
    bsf     SSP1CON2,SEN	; initiate I2C bus start condition
common_start:			; (common to regular and repeated start.)
    call    OnNext_I2c_IRQ
    clrf    i2c_active_slave	; slave not yet known to be 'at home'
; The first interrupt after we cause the start condition gets to here:
    movf    i2c_slave,w		; bit 0 = R/W has already been manipulated
    movwf   SSP1BUF		; write I2C address of our slave to i2c_bus.
  if 0
    movlw   0x41
    call    UART_Put
    banksel SSP1CON2		; select SFR bank
  endif
; We privately remember the slave address and R/W bit so that, following a
; a callback, we can correctly identify repeated start and other conditions.
    call    OnNext_I2c_IRQ	; proceed when slave address has been written
;The first interrupt after we write the slave address gets to here:
    btfsc   SSP1CON2,ACKSTAT	; did our presumed slave acknowledge?
    bra	    IO_error		; no? waste no more time. get off i2c bus asap.
    movf    i2c_slave,w		; this slave had responded to its address
    movwf   i2c_active_slave	; save a copy of its address
    btfsc   i2c_slave,0		; what must we do (first)? read or write?
    bra	    straight_read	; immediate read (e.g. no sub-address to write).
write_next:
    movf    INDF1,w             ; retrieve next byte to write into w
    incf    FSR1,f              ; increment pointer
    movwf   SSP1BUF		; write the data byte
  if 0
    movlw   0x44
    call    UART_Put
    banksel SSP1CON2		; select SFR bank
  endif
    call    OnNext_I2c_IRQ	; proceed when the data byte has been written
    decf    i2c_count,f		; and another one bites the bus!
    btfss   STATUS,Z		; any more to write from this buffer?
    bra	    write_next		; YES: get on with it.
    bra	    do_callback		; NO: time for callback!

straight_read:
    bsf	    SSP1CON2,RCEN	; enable receive
    call    OnNext_I2c_IRQ	; must wait for slave to pulse out data byte
    movf    SSP1BUF,w
    movwf   INDF1		; STUB! must index buffer here!
    incf    FSR1,f              ; increment pointer
    decf    i2c_count,f		; count down. also determines choice of ACK/NACK
    btfsc   STATUS,Z
    bra	    do_callback ; DoneLastRead    

; branch in here if we need to do more I/O to same slave. callback will have
; supplied new buffer address and count.
more_of_same:
    btfss   i2c_slave,0		; what must we do (first)? read or write?
    bra	    write_next
; we didn't (yet) acknowledge the last byte of the previous buffer because we
; didn't know whether it was the last. we now know that it is wasn't.
sendACK:
    bcf	    SSP1CON2,ACKDT	; must ACK to encourage slave to keep sending.
    bsf     SSP1CON2,ACKEN	; initiate acknowledge sequence
    call    OnNext_I2c_IRQ	; proceed when ACK bit has been sent
    bra	    straight_read	; now we must invite the next byte.
    
IO_error:
    bsf     i2c_flags,1		; set error flag. callback may clear this.
do_callback:
    movf   i2c_callbackH,w
    movwf  PCLATH
    movf   i2c_callbackL,w
    movwf  PCL			; branch to context-dependent handler

resuming:
; i2c_active_slave is kind of private but may be cleared during callback to
; inhibit chaining and use of repeated start.
    btfsc   i2c_flags,1		; error detected (and not cancelled in callback)
    bra	    this_slave_done	; YES:-> finish transfer,quit the i2c bus asap.
    movf   i2c_count,w		; more I/O to be done before stop cond.?
    btfsc   STATUS,Z
    bra	    this_slave_done		; NO:-> finish transfer,quit the i2c bus asap.
				; YES:-> must check for special cases!
    movwf   i2c_active_slave	; what slave were we dealing with
    subwf   i2c_slave,w		; same slave and same direction (R/W)?
    btfsc   STATUS,Z
    bra	    more_of_same	; YES:-> carry on.
    andlw   0xfe			; NO:-> Read after write to same slave address?
    btfss   STATUS,Z
    bra	    this_slave_done	; NO: => must stop 
				; yes => need to give repeated start.
    bsf     SSP1CON2,RSEN	; initiate I2C bus REPEATED start condition
    bra	    common_start

this_slave_done:
    btfss   i2c_slave,0		; what were we doing? reading or writing?
    bra	    give_stop_cond	; writing: => can give stop condition now.
    movf    i2c_active_slave,w	; had we actually read a byte yet?
    btfsc   STATUS,Z		; YES:-> NACK the last received byte
    bra	    give_stop_cond	; NO: > mustn't try and NACK byte we never got!
    
sendNACK:			; reading: => must NACK first.
    bsf	    SSP1CON2,ACKDT	; must NACK to make slave get off the bus!
    bsf     SSP1CON2,ACKEN	; initiate acknowledge sequence
    call    OnNext_I2c_IRQ	; proceed when NACK bit has been sent
give_stop_cond:
    bsf	    SSP1CON2,PEN	; generate stop condition
    call    OnNext_I2c_IRQ	; proceed when stop condition has been given.
    bcf     i2c_flags,0		; = operation completed
    btfsc   i2c_flags,1		; error detected (and not cancelled in callback)
    bra	    do_callback		; YES:-> just do the callback.
    movf    i2c_count,w		; follow up I/O to be done?
    btfss   STATUS,Z
    bra	    new_start		; YES: > give start cond, address new slave etc.
    bra	    do_callback		; NO:-> just do the callback.
    

I2c_Drive_then_stop:
    clrf    i2c_flags
    call    I2c_Drive		; follows through some interrupts later!
    call    I2c_Drive		; follows through some interrupts later!
    return

; I2c_sync_Xfer does a simple read or write transfer and waits for completion.
I2c_sync_Xfer:
    call    I2c_Drive_then_stop	; ordinary call (for a change!)
I2c_wait:
    banksel SSP1CON2		; select SFR bank
    btfsc   i2c_flags,0		; transfer still in progress?
    goto    $-1
    return

I2c_sync_Xfer_byte:
    banksel SSP1CON2		; select SFR bank
    movwf   i2c_buf		; byte to be written if writing
    call    I2c_Use_Internal_Buffer
    movlw   1
    movwf   i2c_count
    call    I2c_sync_Xfer
    movf    i2c_buf,w		; byte just read if reading
    return

I2c_Probe:
    banksel SSP1CON2		; select SFR bank    
    clrf    i2c_slave
    incf    i2c_slave
    clrf    i2c_flags
    clrf    i2c_flags
I2c_Probe_next:
    movlw   1
    movwf   i2c_count
    movlw   2
    addwf   i2c_slave,f
    btfsc   STATUS,C
    bra	    I2c_Probe_next
    ;;bcf	    i2c_flags,1
    call    I2c_Use_Internal_Buffer
    call    I2c_Drive
    lsrf   i2c_slave,w
    
    btfss   i2c_flags,1
    call    UART_Print
    banksel SSP1CON2		; select SFR bank    
    bcf     i2c_flags,1		; = remove error condition
    goto    I2c_Probe_next

I2c_Test:
;    call    UART_Get
;    call    UART_Print
    goto    I2c_Probe

    banksel SSP1CON2		; select SFR bank
    movlw   0x70		; prepare to access i2c device PCF8574A 0111 000 
    movwf   i2c_slave		; this is an 8-bit address!
    movlw   0xff
I2c_write_loop:
    call    I2c_sync_Xfer_byte
;;    addlw   0xff		; W -= 1
;;    goto    I2c_write_loop
    bsf    i2c_slave,0		; now set the R bit!
I2c_read_loop:
    banksel SSP1CON2		; select SFR bank    
    incf    i2c_count,f		; count will have gone to zero.
    call    I2c_sync_Xfer
    btfsc   WREG,7		; look for IO pin 7 being pulled down
    goto    I2c_read_loop    
    goto    I2c_read_loop	; set breakpoint here to detect low pin7.
  
    END

I