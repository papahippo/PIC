    #include <p16f1619.inc>
    __CONFIG _CONFIG1, (_FOSC_INTOSC & _PWRTE_OFF & _MCLRE_ON & _CP_OFF & _BOREN_ON & _CLKOUTEN_OFF & _IESO_OFF & _FCMEN_OFF);
    __CONFIG _CONFIG2, (_WRT_OFF & _PLLEN_OFF & _STVREN_OFF & _LVP_ON);
    __CONFIG _CONFIG3, _WDTE_OFF

    errorlevel -302                     ;supress the 'not in bank0' warning

    ; general purpose memory usage:
    cblock 0x70                         ;shared memory location that is accessible from all banks
    saveTOSH
    saveTOSL
     endc

;*******    INTERRUPT CONTEXT SAVE/RESTORE VARIABLES
INT_VAR        UDATA   0x20              ; create uninitialized data "udata" section
w_temp           RES     1               ;
status_temp      RES     1               ;
pclath_temp      RES     1
irq_count        RES     1

INT_VAR1       UDATA   0xA0              ; reserve location 0xA0
w_temp1          RES     1



;----------------------------------------------------------------------
;   ********************* RESET VECTOR LOCATION  ********************
;----------------------------------------------------------------------
RESET_VECTOR  CODE    0x000              ; processor reset vector
    movlw  high  Start               ; load upper byte of 'start' label
    movwf  PCLATH                    ; initialize PCLATH
    goto   Start                     ; go to beginning of program

    
;----------------------------------------------------------------------
;  ******************* INTERRUPT VECTOR LOCATION  *******************
;----------------------------------------------------------------------
INT_VECTOR   CODE    0x004               ; interrupt vector location
    movwf   w_temp                   ; save off current W register contents
    movf    STATUS,w                 ; move status register into W register
    clrf    STATUS                   ; ensure file register bank set to 0
    movwf   status_temp              ; save off contents of STATUS register
    movf    PCLATH,w
    movwf   pclath_temp              ; save off current copy of PCLATH
    clrf    PCLATH	             ; reset PCLATH to page 0

    call    HandleTimer1
		;; ..........................
exit_isr 
    clrf    STATUS                   ; ensure file register bank set to 0
    movf    pclath_temp,w
    movwf   PCLATH                   ; restore PCLATH
    movf    status_temp,w            ; retrieve copy of STATUS register
    movwf   STATUS                   ; restore pre-isr STATUS register contents
    swapf   w_temp,f                 ;
    swapf   w_temp,w                 ; restore pre-isr W register contents
    retfie                           ; return from interrupt

HandleTimer1:
    banksel PIE1                     ; select SFR bank
    btfss   PIE1,TMR1IE              ; test if interrupt is enabled
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

;  ******************* INITIALIZE TIMER1 MODULE  *******************
;----------------------------------------------------------------------
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
    bsf	    PIE1,TMR1IE              ; enable Timer1 interrupt
    return                         ; return from subroutine
     
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

    
Start:
    banksel OSCCON              ; bank1
    movlw   b'11111000'         ; set cpu clock speed of 500KHz ->correlates to (1/(500K/4)) for each instruction
    movwf   OSCCON              ; move contents of the working register into OSCCON

    call    LED_Init
    call    Timer1_Init
    banksel INTCON
    bsf	    INTCON,PEIE               ; enable ??? interrupt
    bsf	    INTCON,GIE               ; enable global interrupt

    call    LED_Cycle
MainLoop:
    nop
    bra	    MainLoop 

LED_Cycle:		;D7654
    call    Timer1_Await
    bcf     LATA,2
    bcf	    LATC,5	; 00xx
    call    Timer1_Await
    bsf	    LATA,2	; 01xx
    call    Timer1_Await
    bcf     LATA,2
    bsf	    LATC,5	; 10xx
    call    Timer1_Await
    bsf     LATA,2
    bsf	    LATC,5	; 11xx
    bra	    LED_Cycle

    end