    #include <p16f1619.inc>
    __CONFIG _CONFIG1, (_FOSC_INTOSC & _PWRTE_OFF & _MCLRE_ON & _CP_OFF & _BOREN_ON & _CLKOUTEN_OFF & _IESO_OFF & _FCMEN_OFF);
    __CONFIG _CONFIG2, (_WRT_OFF & _PLLEN_OFF & _STVREN_OFF & _LVP_ON);
    __CONFIG _CONFIG3, _WDTE_OFF

    errorlevel -302                     ;supress the 'not in bank0' warning

    extern Timer1_Init, Timer1_IRQ
    extern LED_Init, LED_Cycle,
    extern UART_Init, UART_Get, UART_Put
    extern I2c_Init, I2c_Test, I2c_IRQ

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

    call    I2c_IRQ
    ;call    Timer1_IRQ
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
    
Start:
    banksel OSCCON              ; bank1
    movlw   b'11111000'         ; set cpu clock speed of 500KHz ->correlates to (1/(500K/4)) for each instruction
    movwf   OSCCON              ; move contents of the working register into OSCCON

    ;call    LED_Init
    ;call    Timer1_Init
    ;call    UART_Init
    call    I2c_Init
    banksel INTCON
    bsf	    INTCON,PEIE               ; enable ??? interrupt
    bsf	    INTCON,GIE               ; enable global interrupt

    ;call    LED_Cycle
    
    call I2c_Test
MainLoop:
    ;movlw   0x55		    ; 'E' 
    ;call    UART_Get
    ;call    UART_Put
    bra	    MainLoop 

    end