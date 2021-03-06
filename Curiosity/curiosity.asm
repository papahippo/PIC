    #include <p16f1619.inc>
    __CONFIG _CONFIG1, (_FOSC_INTOSC & _PWRTE_OFF & _MCLRE_ON & _CP_OFF & _BOREN_ON & _CLKOUTEN_OFF & _IESO_OFF & _FCMEN_OFF);
    __CONFIG _CONFIG2, (_WRT_OFF & _PLLEN_OFF & _STVREN_OFF & _LVP_ON);
    __CONFIG _CONFIG3, _WDTE_OFF

    errorlevel -302                     ;supress the 'not in bank0' warning

    extern Timer1_Init, Timer1_IRQ
    extern LED_Init, LED_Test
    extern UART_Init, UART_Get, UART_Put, UART_Test
    extern I2c_Init, I2c_Init_400KHz, I2c_Test, I2c_IRQ


;----------------------------------------------------------------------
;   ********************* RESET VECTOR LOCATION  ********************
;----------------------------------------------------------------------
RESET_VECTOR  CODE    0x000          ; processor reset vector
    movlw  high  Start               ; load upper byte of 'start' label
    movwf  PCLATH                    ; initialize PCLATH
    goto   Start                     ; go to beginning of program

    
;----------------------------------------------------------------------
;  ******************* INTERRUPT VECTOR LOCATION  *******************
;----------------------------------------------------------------------
INT_VECTOR   CODE    0x004               ; interrupt vector location
    ;;banksel LATA               
    ;;bsf     LATA,2

    movlw   high I2c_IRQ
    movwf   PCLATH	             ; reset PCLATH to page 0
    call    I2c_IRQ
    movlw   high Timer1_IRQ
    movwf   PCLATH	             ; reset PCLATH to page 0
    call    Timer1_IRQ
    ;;banksel LATA               
    ;;bcf     LATA,2
		;; ..........................
exit_isr 
    retfie                           ; return from interrupt
    
Start:
    banksel OSCCON              ; bank1
    movlw   b'11111000'         ; set cpu clock speed of 500KHz ->correlates to (1/(500K/4)) for each instruction
    movwf   OSCCON              ; move contents of the working register into OSCCON

    call    UART_Init
    call    Timer1_Init
    call    LED_Init
    call    I2c_Init_400KHz
    banksel INTCON
    bsf	    INTCON,PEIE               ; enable ??? interrupt
    bsf	    INTCON,GIE               ; enable global interrupt

    call    LED_Test
    call    I2c_Test
    ;call    UART_Test
MainLoop:
    ;movlw   0x55		    ; 'E' 
    ;call    UART_Get
    ;call    UART_Put
    bra	    MainLoop 

    end