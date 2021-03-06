#include <p16f1619.inc>
#define FOSC D'32000000'
#define  I2CClock    D'400000'           ; define I2C bite rate
#define  ClockValue400KHz  (((FOSC/I2CClock)/4) -1) ; 

I2c_VAR	           UDATA 0x220	; accessible from SSP register bank!
i2c_control	    RES	1	; public parameter, also used internally
i2c_slave	    RES	1       ; public parameter; n.b. 8-bit address + R/W
i2c_count	    RES	1	; passed in W! buffer size to read/write
i2c_callbackL	    RES	1	; public parameters = address of code following 
i2c_callbackH	    RES	1	;      call to I2c_Drive
i2c_bufPtrL	    RES	1 
i2c_bufPtrH	    RES	1
i2c_IRQ_TOSL	    RES 1
i2c_IRQ_TOSH	    RES 1
i2c_bad_bits	    RES 1
i2c_buf		    RES	.22
; remaining three definition related only to 'scattered_read' example
sr_head		    RES .12
sr_segment_count    RES 1	; dangerously in-between for testing purposes!
sr_tail		    RES 4

I2c CODE			; let linker place this

    global  I2c_Init_400KHz, I2c_Init, I2c_IRQ, I2c_Drive, I2c_Use_Internal_Buffer
    global  I2c_Test, I2c_Probe
    
    extern UART_Get, UART_Put, UART_Print

 
; ------------------------------------------------------------------------------
; 'I2c_Init_400KHz' initialized the I2c bus for master operation at 400kHz.
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
; problematic? unnecesary? ... call    OnNext_I2c_IRQ
    return

; ------------------------------------------------------------------------------
; A small buffer (22 bytes) is reserved within the SSP1 bank for small i2c
; transfers. A conveninece function is provided to load up FSR1 to use this:
I2c_Use_Internal_Buffer:
    banksel SSP1CON2		; select SFR bank
    movlw   high i2c_buf
    movwf   FSR1H
    movlw   low i2c_buf
    movwf   FSR1L
    return

; ------------------------------------------------------------------------------
; A call to 'OnNext_I2c_IRQ' (just below) saves the return address and pops
; it from the stack then returns to the caller's caller. The code at the saved
; return address gets executed on the next I2c IRQ (hence the name!).
OnNext_I2c_IRQ:
    movf    FSR1L,w
    movwf   i2c_bufPtrL
    movf    FSR1H,w
    movwf   i2c_bufPtrH
    banksel TOSL
    movf    TOSL,w
    banksel SSP1CON2
    movwf   i2c_IRQ_TOSL
    banksel TOSH
    movf    TOSH,w
    decf    STKPTR,f		; 'pop' the return address from the stack.
    banksel SSP1CON2
    movwf   i2c_IRQ_TOSH
    banksel PIE1		; now our 'vector' is written, it is safe to allow
    bsf	    PIE1,SSP1IF		; the next interrupt to arrive.
    banksel SSP1BUF
    return

; ------------------------------------------------------------------------------
; 'I2c_IRQ' is called every time an interrupt is detected. The code here must
; first establish whether there really is an I2C interrupt and if not, get out
; of here quickly!
I2c_IRQ:
    banksel PIE1
    btfss   PIE1,SSP1IE		; test if interrupt is enabled
    return
    ;;; goto	test_buscoll   ; no, so test for Bus Collision Int
    banksel PIR1
    btfss   PIR1,SSP1IF		; test for SSP H/W flag
; an unexpected return here can be symptomatic of a an i2c bus error, in which 
; case bit 3 of PIR2 will be set. It seems the hardware can get into a state
; where all attempts to use I2c lead to such a condition and the only fix known
; to me is to power down and go away for an hour or two! 

    return			; no I2C IRQ so return to generic IRQ code
    bcf	    PIR1,SSP1IF		; clear SSP H/W flag
; We disable SSP (hence I2c) interrupts during the handler; this is necessary to
; make our dispaching code safe but of course means a little extra IRQ latency.
    banksel PIE1
    bcf	    PIE1,SSP1IF		; interrupt from occurring before our context is set
    banksel SSP1CON2
    movf    i2c_bufPtrH,w
    movwf   FSR1H
    movf    i2c_bufPtrL,w
    movwf   FSR1L
    movf    i2c_IRQ_TOSH,w	; we now dispatch (tricky goto!) the code address
    movwf   PCLATH		; set by the last call to 'OnNext_I2c_IRQ'.
    movf    i2c_IRQ_TOSL,w
    movwf   PCL			; branch to context-dependent handler
; The above instructions route us to the instruction immeditaely following the
; most recently executed "call    OnNext_I2c_IRQ". This will be somewhere within
; the driver code below...

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
; i2c_control:  this byte is a pattern of  bits which in general is a
;		command to the driver telling it what to do next.
; ------------------------------------------------------------------------
; bit		meaning
; ---           -------  
;  7		all finished.
;  6		NAK received.
;  5		discrepancy found.
;  4		verify required.
;  3		acknowledge cycle owed.
;  2		stop condition to be given 
;  1		start condition to be given
;  0		(bit 1 set)=> repeated start; (bit 0 clear)=> more I/O
;
; i2c_slave	This must be expressed as an eight bit value: bits 7-1 =
;		hardware 7-bit salve address, bit 0 = 1/0 for R/W respectively.
; i2c_count	is a single byte indicating how many data bytes need to be
;		read or written before calling the user's callback. A zero value
;		is (currently under review) not allowed so 1<=i2c_count<=255.
;		Longer frame transfers can be aceived by calling I2c_Drive again
;		from the user's callback routine.
; The address of the data buffer is passed in registers FSR1H and FSR1L. This is
; saved, used, and updated by the driver. The updated value is passed to the
; callback routine in FRS1H adn FSR1L.

I2c_Clean_Start:
    clrf    i2c_control
I2c_Start:
    bsf	    i2c_control,1	; start condition required
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
; now save buffer address, passed in FSR1:
    movf    FSR1L,w
    movwf   i2c_bufPtrL
    movf    FSR1H,w
    movwf   i2c_bufPtrH
; Now look what action is required.
    btfss   i2c_control,2	; is an i2c_stop required?
    bra	    dont_stop		
; stop condition required; but maybe need to issue NAK first:
    btfss   i2c_control,3	; ACK cycle pending?
    bra	    give_stop_cond	; writing: => can give stop condition now.    
sendNACK:			; we'd really started reading: => must NACK first.
    bsf	    SSP1CON2,ACKDT	; must NACK to make slave get off the bus!
    bsf     SSP1CON2,ACKEN	; initiate acknowledge sequence
    call    OnNext_I2c_IRQ	; proceed when NACK bit has been sent
give_stop_cond:
    bsf	    SSP1CON2,PEN	; generate stop condition
    call    OnNext_I2c_IRQ	; proceed when stop condition has been given.
    bcf     i2c_control,2	; stop has been done to no longer required.
    bcf     i2c_control,3	; erase what was NAK indicator.
; 'i2c_control' can now be interpreted just  as in the non-stopping case!
dont_stop:
; Do we need to issue a start - or maybe repeated start - condition:
    btfss   i2c_control,1
    bra	    no_start
; If we're arriving here after a stop condition, bit 0 may be set....
    btfss   i2c_control,0	; b'10' => start; b'11' => repeated start
    bra	    give_start_cond

    bsf     SSP1CON2,RSEN	; initiate I2C bus REPEATED start condition
    bra	    common_start

; Start condition requested.
give_start_cond:
    ;bsf     i2c_control,0	; 1 => Xfer in progress
    btfsc   SSP1STAT,R_NOT_W	; transmit in progress?
    goto    $-1
    movf    SSP1CON2,w
    andlw   0x1F		; mask out non-status bits
    btfss   STATUS,Z
    goto    $-3
    bcf	    SSP1CON2,ACKDT	; set ACK to normal state
    bsf     SSP1CON2,SEN	; initiate I2C bus start condition
common_start:			; (common to regular and repeated start.)
    bcf	    i2c_control,1	; start no longer required
    bcf	    i2c_control,7	; clear the all-done bit.
    call    OnNext_I2c_IRQ
; The first interrupt after we cause the start condition gets to here:
    movf    i2c_slave,w		; bit 0 = R/W has already been manipulated
    movwf   SSP1BUF		; write I2C address of our slave to i2c_bus.
    call    OnNext_I2c_IRQ	; proceed when slave address has been written
;The first interrupt after we write the slave address gets to here:
    btfsc   SSP1CON2,ACKSTAT	; did our presumed slave acknowledge?
    bra	    slave_NACKed	; no? waste no more time. get off i2c bus asap.
; following addition to support zero-length transfer under review!
    ;;movf    i2c_count,f		
    ;;btfsc   STATUS,Z		; check for zero length transfer
    ;;bra	    do_callback
    btfsc   i2c_slave,0		; what must we do (first)? read or write?
    bra	    straight_read	; immediate read (e.g. no sub-address to write).
    bra	    write_next
slave_NACKed:
    bsf     i2c_control,6	; set error (NAK) flag. callback may clear this.
    bra	    do_callback
write_next:
    movf    INDF1,w             ; retrieve next byte to write into w
    incf    FSR1,f              ; increment pointer
    movwf   SSP1BUF		; write the data byte
    call    OnNext_I2c_IRQ	; proceed when the data byte has been written
    decf    i2c_count,f		; and another one bites the bus!
    btfss   STATUS,Z		; any more to write from this buffer?
    bra	    write_next		; YES: get on with it.
    bra	    do_callback		; NO: time for callback!

straight_read:
    bsf	    SSP1CON2,RCEN	; enable receive
    call    OnNext_I2c_IRQ	; must wait for slave to pulse out data byte
    movf    SSP1BUF,w
    btfsc   i2c_control,4	; verify required?
    bra	    verify
    movwf   INDF1		;
verified_ok:
    incf    FSR1,f              ; increment pointer
    decf    i2c_count,f		; count down. also determines choice of ACK/NACK
    btfsc   STATUS,Z
    bra	    postpone_ACK
sendACK:
    bcf	    SSP1CON2,ACKDT	; must ACK to encourage slave to keep sending.
    bsf     SSP1CON2,ACKEN	; initiate acknowledge sequence
    call    OnNext_I2c_IRQ	; proceed when ACK bit has been sent
    bra	    straight_read	; now we must invite the next byte.

verify:
    xorwf   INDF1,w		; value read is same as buffer content?
    btfsc   STATUS,Z
    bra	    verified_ok		; yes! carry on reading
    movwf   i2c_bad_bits	; 1's here are bits in error.
    bsf	    i2c_control,5	; no! flag up verification error.
postpone_ACK:
    bsf	    i2c_control,3	; acknowledge cycle owed.
    bra	    do_callback

; Start condition is not required; must check for the 'NOOP' case!
no_start:
    btfss   i2c_control,0	; more I/O
    bra	    do_final_callback
    bcf	    i2c_control,0	; don't presume more continues after this one!
    btfsc   i2c_control,3		; still owing an acknowledge cycle?
; we didn't (yet) acknowledge the last byte of the previous buffer because we
; didn't know whether it was the last. we now know that it is wasn't.
    bra	    sendACK
    bra	    write_next

do_final_callback:
    bsf     i2c_control,7	; mark transfer as really finished.
do_callback:
    movf   i2c_callbackH,w
    movwf  PCLATH
    movf   i2c_callbackL,w
    movwf  PCL			; branch to context-dependent handler
   

; ============================================================================
; i2c_Simple_Transfer does a simple i2c transfer including start and stop
; conditions, with no real callback functionality.
i2c_Simple_Transfer:
    call    I2c_Clean_Start	; follows through some interrupts later!
; the code below is the first callback routine!
    bsf	    i2c_control,2	; request no more I/O no start, just stop!
    call    I2c_Drive		; follows through some interrupts later!
; the code below is the first callback routine!
    return			; no follow action in interrupt context.

; ============================================================================
; I2c_Sync_Xfer does a simple read or write transfer and waits for completion.
I2c_Sync_Xfer:
    call    i2c_Simple_Transfer	; ordinary call (for a change!)
I2c_wait:
    banksel SSP1CON2		; select SFR bank
    btfss   i2c_control,7	; transfer finished?
    goto    $-1
    return

; ============================================================================
; Special function for the case where just one byte is to be transferred.

I2c_Sync_Xfer_byte:
    banksel SSP1CON2		; select SFR bank
    movwf   i2c_buf		; byte to write if writing
    movlw   1
    movwf   i2c_count
    call    I2c_Use_Internal_Buffer
    call    I2c_Sync_Xfer
    movf    i2c_buf,w		; byte just read if reading
    return

; ==============================================================================
; The rest of this source file contains example/test code.
; So far, I've selected which test to run by the age-old method of
; [un]commenting statements. I intend to add some primitive menu system
; some day soon!
I2c_Test:
;   goto    I2c_test_scattered_read
;   goto    I2c_Test_dummy_verify ; I2c_Probe
    bra    I2c_Probe
;    goto    I2c_Temp_test

; ------------------------------------------------------------------------------
; 'I2c_Temp_test' currently does very little. It just reads the two-byte
; temperature value from the temperature register. It really ought to - at 
; the very least - first write the pointer byte to address the temperature
; register rather than relying on the power-on default! see LM75A specification.

I2c_Temp_test:
    call    UART_Get
    banksel SSP1CON2		; select SFR bank    
    movlw   0x91
    movwf   i2c_slave
    movlw   2
    movwf   i2c_count
    call    I2c_Use_Internal_Buffer
    call    I2c_Sync_Xfer
    bra	    I2c_Temp_test
; ==============================================================================
; Utility function to identify which i2c slave addresses are occupied.
I2c_Probe:
    call    UART_Get
    banksel SSP1CON2		; select SFR bank    
    clrf    i2c_slave
    bsf     i2c_slave,0		; start by reading from slave with 7-bit addr 0.
    clrf    i2c_control
I2c_Probe_next:
    movlw   2
    addwf   i2c_slave,f		; step on to next slave
    btfsc   STATUS,C		; avoid 0  (=general call address)
    bra	    I2c_Probe
; We always try to read two bytes; this is because certain devices (notably 'my'
; LM75A!) cannot handle a single-byte read and can cause a bus lock-up.
    movlw   2
    movwf   i2c_count
    call    I2c_Use_Internal_Buffer
    call    I2c_Sync_Xfer
    lsrf    i2c_slave,w		; recover 7-bit address. n.b. only changes W reg!
    btfss   i2c_control,6	; ACK given?
    call    UART_Print		; yes! print out 7-bit i2c slave address.
    banksel SSP1CON2		; select SFR bank
    bra    I2c_Probe_next


I2c_Test_synch_echo:
; input character from UART, write to I/O expander, read back, output ASCII value
; to UART. character should be unchanges except when I/O expander pins
; are pulled down externally. On my breadboard, bits 5 and7 are pulled down.
; (null character or) space character input terminates test.
;
    banksel SSP1CON2		; select SFR bank
    movlw   0x70		; prepare to access i2c device PCF8574A 0111 000 
    movwf   i2c_slave		; this is an 8-bit address!
    call    UART_Get
    call    I2c_Sync_Xfer_byte
    bsf     i2c_slave,0		; now set the R bit!
    call    I2c_Sync_Xfer_byte
    call    UART_Print
    btfss   STATUS,Z
    goto    I2c_Test_synch_echo
    movlw   ";"
    call    UART_Put 

I2c_Test_dummy_verify:
; The verify function is really intended for making extra sure that e.g.
; register settings of an I2c amplifier control chip have been written 
; correctly. This test, however, uses a simple I/O expander. This has the advantage
; that a 'verify' error can be simulated simply by tying down one or more I/O pins
; and writing one(s) to the corresponding bit(s).
    call    UART_Get
    call    dummy_write_verify
    call    I2c_wait
    movf    i2c_buf,w
    call    UART_Print
    movlw   "="			; Preset to ouput '=' for all ok case.
    banksel SSP1CON2		; select SFR bank
    btfsc   i2c_control,6	; Was our slave at home and answering the door?
    movlw   "_"			; No! (NACK) 
    btfsc   i2c_control,5	; Verify error?
    movlw   "?"
    call    UART_Put
    bra	    I2c_Test_dummy_verify

dummy_write_verify:
    banksel SSP1CON2		; select SFR bank
    movwf    i2c_buf
    clrf    i2c_control
    movlw   0x70		; prepare to access i2c device PCF8574A 0111 000 
    movwf   i2c_slave		; Note that this is an 8-bit address!
now_verify:
    call    I2c_Use_Internal_Buffer
    movlw   1
    movwf   i2c_count
    call    I2c_Start
    bsf	    i2c_control,2	; i2c stop needed before the next i2c start!
    call    I2c_Drive		; don't delay the stop
    btfss   i2c_control,6	; Is our slave at home and answering the door?
    btfsc   i2c_control,4	; Yes! are we already doing the verify
; Either way, Just return (we're in interrupt context remember!)
    return			; Main-line code will also inspect i2c_control

; We just did teh write action and the ACKs were ok.
    bsf	    i2c_control,4	; must do verify now.
    bsf	    i2c_slave,0		; switch to read address
    bra	    now_verify

I2c_test_scattered_read:
    call    UART_Get
    call    i2c_start_scattered_read
    bra	    I2c_test_scattered_read
i2c_start_scattered_read:
; pretend we're reading a long i2c 'frame' cosisting of a 12-byte 'head',
; 7 x 24-byte 'segments' and a 4-byte 'tail'.
; The segments are read into the same offset in banks 5-11 to facilitate
; indexing data.
    call    I2c_Use_Internal_Buffer  ; also selects SFR bank and i2c_buf<-W
    movlw   0x70		; prepare to write to i2c device PCF8574A
    movwf   i2c_slave		; Note that this is an 8-bit address!
    movlw   1
    movwf   i2c_count
    call    I2c_Clean_Start
    movlw   high sr_head
    movwf   FSR1H
    movlw   low  sr_head
    movwf   FSR1L
    movlw   0x71		; prepare to read from i2c device PCF8574A
    movwf   i2c_slave		; Note that this is an 8-bit address!
    movlw   .12
    movwf   i2c_count
    bsf	    i2c_control,2	; require stop before start.
    call    I2c_Start
; 'return' here in IRQ context when header has been read.
    movlw   2
    movwf   FSR1H
    movlw   0xd0
    movwf   FSR1L
read_segment:
    movlw   .24
    movwf   i2c_count
    bsf	    i2c_control,0	; request more I/O without start or stop
    call    I2c_Drive
; 'return' here in IRQ context when a segment has been read has been read.
    movlw   0x68		; step on to next page
    addwf   FSR1L,f
    btfsc   STATUS,C
    incf    FSR1H
    movlw   6
    subwf   FSR1H,w		; no carry => we've stepped on to page 12.
    btfss   STATUS,C
    bra	    read_segment	; go read next segment
; all 7	segments done; now read the 4-byte tail.
    movlw   high sr_tail
    movwf   FSR1H
    movlw   low  sr_tail
    movwf   FSR1L

    movlw   4
    movwf   i2c_count
    bsf	    i2c_control,0	; request more I/O without start or stop
    call    I2c_Drive
; 'return' here after writing tail.
    bsf	    i2c_control,2	; request stop condition
    call    I2c_Drive		; we're all done, no callback required.
    return
    END

