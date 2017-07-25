   #include <p16f1619.inc>
 
       ; general purpose memory usage:
    cblock 0x70                         ;shared memory location that is accessible from all banks
    saveTOSH
    saveTOSL
     endc

Timer1 CODE                      ; let linker place this

    global Timer1_Init, Timer1_Handle, Timer1_Await
Timer1_Init:
    banksel T1CON                  ; select SFR bank	
    movlw   b'00110000'            ; 1:8 prescale, 100mS rollover
    movwf   T1CON                  ; initialize Timer1

    movlw   0x58                   ;
    movwf   TMR1L                  ; initialize Timer1 low
    movlw   0x9E                   ;
    movwf   TMR1H                  ; initialize Timer1 high

    bcf	    PIR1,TMR1IF            ; ensure flag is reset
    bsf	    T1CON,TMR1ON           ; turn on Timer1 module
    banksel PIE1
    bsf	    PIE1,TMR1IE            ; enable Timer1 interrupt
; The followng call is just a long-stop in-case no-one else claimms timer1
; before the interrupt occurs. In that case the following return is harmless.
    call    Timer1_Await
    return                         ; return from subroutine
     
Timer1_Handle:
    banksel PIE1                   ; select SFR bank
    btfss   PIE1,TMR1IE            ; test if interrupt is enabled
    return

    banksel PIR1
    btfss   PIR1,TMR1IF              ; test if Timer1 rollover occured
    return
    
    banksel T1CON                    ; select SFR bank
    bcf	    T1CON,TMR1ON             ; turn off Timer1 module
    movlw   0x58                     ;
    addwf   TMR1L,f                  ; reload Timer1 low
    movlw   0x9E                     ;
    movwf   TMR1H                    ; reload Timer1 high

    banksel PIR1
    bcf	    PIR1,TMR1IF              ; clear Timer1 H/W flag
    bsf	    T1CON,TMR1ON             ; turn on Timer1 module

    movf   saveTOSL,w
    movwf  PCL

Timer1_Await:
     banksel TOSL
     movf	TOSL,w
     decf	STKPTR
     movwf	saveTOSL
     return

    END