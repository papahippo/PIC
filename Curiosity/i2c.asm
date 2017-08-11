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
i2c_control	    RES	1	; public parameter, also used internally
i2c_slave	    RES	1       ; public parameter; n.b. 8-bit address + R/W
i2c_count	    RES	1	; passed in W! buffer size to read/write
i2c_callbackL	    RES	1	; public parameters = address of code following 
i2c_callbackH	    RES	1	;      call to I2c_Drive
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

; ==============================================================================
; all I2C reads and writes go (directly or indirectly) via I2c_Drive.
; The function 'I2c_Drive' returns via the user's callback
; function before issuing the stop condition and - in the case of a read
; operation - before ACKing or NACKing the last received byte. A second call to
; I2c_Drive is needed to [perform the last ACK/NACK and] issue the stop condition.
; This complication is 'hidden' when using the simple 'I2c_Sync_Xfer' function
; (see below). Its purpose is to facilitate:
;   - i2c 'repeated start' implementation.
;   - continuous input or ouput of more bytes than are contiguously available
;     in the PIC memory.
;   - other chained operations; one can compose a kind of 'i2c management thread'
;     without the need for any OS. This must be used wisely of course like all
;     good things!
; The following variables form an "I2c control block":
; I2c_control:  this byte is a pattern of four bits which in general is a
;		command to the driver telling it what to do next.
;		bit 0 however is sometimes an error indication by the driver
;		(A in table below):
;		A=0 => ok; A=1 => NACK received. X => don't care
; bit  3210
; ---  ----
;
;      0000 ; 'NO-OP'	   = do no I/O at all; just call the callback.
;      0001 ; 'CONTINUE'   = don't stop, do more R or W to same slave.
;      0010 ; 'START'	   = give i2c start condition then proceed with I/O.
;      0011 ; 'REPEATED START' = give repeated start, then continue with I/O.
;                    N.B caller must first change R/W bit as (usually) required.
;      010A ; 'STOP'	   = give i2c_stop condition.
;      011A ; 'STOP_START_NEW'  ; i2c_slave may be different to last 'START'.
;      1XXA ; 'FINISHED'   = all done; do not call 'I2c_Drive' again with this value!
; I2C_Start is a convenience entry point:
I2c_Start:
    movlw   b'010'
    movwf  i2c_control
I2c_Drive:
; First save the callback address:
    banksel TOSL
    movf    TOSL,w		; read lower byte of 'return' address
    banksel SSP1CON2		; select SFR bank
    movwf   i2c_callbackL	; save lower byte of 'return' address
    banksel TOSH
    movf    TOSH,w		; read upper byte of 'return' address
    decf    STKPTR		; 'pop' address; we mustn't return straigh to it!
    banksel SSP1CON2		; select SFR bank
    movwf   i2c_callbackH	; save upper byte of 'return' address
; Now look what action is required.
    btfss   i2c_control,2	; is an i2c_stop required?
    bra	    dont_stop		
; stop condition required; but maybe need to issue NAK first:
    btfss   i2c_slave,0		; what were we doing? reading or writing?
    bra	    give_stop_cond	; writing: => can give stop condition now.
    btfsc   i2c_control,0	; did we read byte(s)? (no NACK on slave adddress)
    bra	    give_stop_cond	; NO: > mustn't try and NACK byte we never got!
    
sendNACK:			; we'd really started reading: => must NACK first.
    bsf	    SSP1CON2,ACKDT	; must NACK to make slave get off the bus!
    bsf     SSP1CON2,ACKEN	; initiate acknowledge sequence
    call    OnNext_I2c_IRQ	; proceed when NACK bit has been sent
give_stop_cond:
    bsf	    SSP1CON2,PEN	; generate stop condition
    call    OnNext_I2c_IRQ	; proceed when stop condition has been given.
    bcf     i2c_control,2	; stop has been done to no longer required.
    bcf     i2c_control,0	; erase what was NAK indicator.
; 'i2c_control' can now be interpreted just  as in the non-stopping case!
dont_stop:
; Do we need to issue a start - or maybe repeated start - condition:
    btfss   i2c_control,1
    bra	    no_start
; If we're arriving here after a stop condition, bit 0 may be set....
    btfsc   i2c_control,2	; don't be fooled by this; repeated start
    bra	    give_start_cond	; after stop is simply not allowed!
    btfss   i2c_control,0	; b'10' => start; b'11' => repeated start
    bra	    give_start_cond	; after stop is simply not allowed!

    bsf     SSP1CON2,RSEN	; initiate I2C bus REPEATED start condition
    bra	    common_start

; Start condition requested.
give_start_cond:
    bsf     i2c_control,0	; 1 => Xfer in progress
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
; The first interrupt after we cause the start condition gets to here:
    movlw   b'100'		; preset next major action to 'STOP'
    movwf   i2c_control
    movf    i2c_slave,w		; bit 0 = R/W has already been manipulated
    movwf   SSP1BUF		; write I2C address of our slave to i2c_bus.
  if 0
    movlw   0x41
    call    UART_Put
    banksel SSP1CON2		; select SFR bank
  endif
    call    OnNext_I2c_IRQ	; proceed when slave address has been written
;The first interrupt after we write the slave address gets to here:
    btfsc   SSP1CON2,ACKSTAT	; did our presumed slave acknowledge?
    bra	    slave_NACKed	; no? waste no more time. get off i2c bus asap.
    btfsc   i2c_slave,0		; what must we do (first)? read or write?
    bra	    straight_read	; immediate read (e.g. no sub-address to write).
    bra	    write_next
slave_NACKed:
    bsf     i2c_control,0	; set error (NAK) flag. callback may clear this.
    bra	    do_callback
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
    bra	    do_callback
sendACK:
    bcf	    SSP1CON2,ACKDT	; must ACK to encourage slave to keep sending.
    bsf     SSP1CON2,ACKEN	; initiate acknowledge sequence
    call    OnNext_I2c_IRQ	; proceed when ACK bit has been sent
    bra	    straight_read	; now we must invite the next byte.

; Start condition is not required; must check for the 'NOOP' case!
no_start:
    btfss   i2c_control,0
    bra	    do_final_callback
; By elimination, i2c_control ends with b'001', i.e. 'CONTINUE' 
    btfss   i2c_slave,0		; what must we do (first)? read or write?
    bra	    write_next
; we didn't (yet) acknowledge the last byte of the previous buffer because we
; didn't know whether it was the last. we now know that it is wasn't.
    bra	    sendACK

do_final_callback:
    bsf     i2c_control,3	; mark transfer as really finished.
do_callback:
    movf   i2c_callbackH,w
    movwf  PCLATH
    movf   i2c_callbackL,w
    movwf  PCL			; branch to context-dependent handler
   

; ============================================================================
; i2c_Simple_Transfer does a simple i2c i2c ttransfer including start and stop
; conditions, with no real callback functionality.
i2c_Simple_Transfer:
    call    I2c_Start		; follows through some interrupts later!
    call    I2c_Drive		; follows through some interrupts later!
    return

; ============================================================================
; I2c_Sync_Xfer does a simple read or write transfer and waits for completion.
I2c_Sync_Xfer:
    call    i2c_Simple_Transfer	; ordinary call (for a change!)
I2c_wait:
    banksel SSP1CON2		; select SFR bank
    btfss   i2c_control,3	; transfer finished?
    goto    $-1
    return

; ============================================================================
; special function for the case where just one byte is to transferred.

I2c_Sync_Xfer_byte:
    banksel SSP1CON2		; select SFR bank
    movwf   i2c_buf		; byte to be written if writing
    call    I2c_Use_Internal_Buffer
    movlw   1
    movwf   i2c_count
    call    I2c_Sync_Xfer
    movf    i2c_buf,w		; byte just read if reading
    return

; ==============================================================================
; Utility function to identify which i2c slave addresses are occupied.
I2c_Probe:
    banksel SSP1CON2		; select SFR bank    
    clrf    i2c_slave
    bsf     i2c_slave,0		; start by reading from slave with 7-biti addr 0.
    clrf    i2c_control
I2c_Probe_next:
    movlw   1
    movwf   i2c_count
    movlw   2
    addwf   i2c_slave,f		; step on to next slave
    btfsc   STATUS,C		; avoid 0  (=general call address)
    bra	    I2c_Probe_next
    bsf     i2c_control,1	; = request start [after stop]
    call    I2c_Use_Internal_Buffer
    call    I2c_Drive
    lsrf    i2c_slave,w		; recover 7-bit address. n.b. only changes W reg!
    btfss   i2c_control,0	; ACK given?
    call    UART_Print		; yes! print out 7-bit i2c slave address.
    banksel SSP1CON2		; select SFR bank
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
    call    I2c_Sync_Xfer_byte
;;    addlw   0xff		; W -= 1
;;    goto    I2c_write_loop
    bsf    i2c_slave,0		; now set the R bit!
I2c_read_loop:
    banksel SSP1CON2		; select SFR bank    
    incf    i2c_count,f		; count will have gone to zero.
    call    I2c_Sync_Xfer
    btfsc   WREG,7		; look for IO pin 7 being pulled down
    goto    I2c_read_loop    
    goto    I2c_read_loop	; set breakpoint here to detect low pin7.
  
    END

I