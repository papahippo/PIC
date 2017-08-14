   #include <p16f1619.inc>
 
LED CODE                      ; let linker place this

    global LED_Init, LED_Test
    extern OnNext_Timer1_IRQ

LED_Init:
    ; Of the followng four LEDS, only D6 and D7 are used in this example.
    ; Note that D5 is not freely available when debugging with MPLAB.
    ; Bit:   ----------------A5 A1 A2 C5 
    ; LED:   ---------------|D4|D5|D6|D7|-
    ; -----------------------------------------
    banksel RA2PPS
    clrf    RA2PPS
    clrf    RC5PPS

    banksel ANSELA              
    bcf     ANSELA,2		; digital I/O mode
    bcf     ANSELC,5

    banksel TRISA               
    bcf     TRISA,2             ;make IO Pin A2 an output = LED D6
    bcf     TRISC,5             ;make IO Pin C5 an output = LED D7

    return

LED_Test:
LED_Cycle:
	  ;state of LEDs D7654
    call    OnNext_Timer1_IRQ; ====
    banksel LATA               
    bcf     LATA,2
    bcf	    LATC,5	; 00xx
    call    OnNext_Timer1_IRQ
    bsf	    LATA,2	; 01xx
    call    OnNext_Timer1_IRQ
    bcf     LATA,2
    bsf	    LATC,5	; 10xx
    call    OnNext_Timer1_IRQ
    bsf     LATA,2
    bsf	    LATC,5	; 11xx
    bra	    LED_Cycle

    END