   #include <p16f1619.inc>
 

UART CODE                      ; let linker place this

    global UART_Init, UART_Get, UART_Put, UART_Print, UART_Test
UART_Init:
    banksel TXSTA
    bsf	    BAUD1CON,BRG16
    movlw   3			; these values give 9600 baud acc. to scope...
    movwf   SPBRGH
    movlw   40			; ... which implies that FOSC = 31.1MHz!?
    movwf   SPBRGL
    bsf	    TXSTA,BRGH
    bsf	    TXSTA,CSRC
    bsf	    TXSTA,TXEN
    bcf	    TXSTA,SYNC
    bsf	    RCSTA,CREN
    bsf	    RCSTA,SPEN
    
    banksel ANSELB
    bcf	    ANSELB,5
    banksel TRISB
    bsf	    TRISB,5
    bsf	    TRISB,7

    banksel RB7PPS
    movlw   0x12
    movwf   RB7PPS	; UART output to go to RB7
    
    banksel RXPPS
    movlw   0x0D
    movwf   RXPPS	; UART input comes from RB5

    return                         ; return from subroutine
     
UART_Get:
    banksel PIR1
    btfss   PIR1, RCIF        ; Bit Test File, Skip if Set
    bra	    UART_Get
    banksel RCREG
    movf    RCREG,w
    return	
     
UART_Print: ; output byte value to UART as two printable hex digits.
    movwf   0x7f
    movlw   "x"
    call    UART_Put
    call    UART_Print_MSD
UART_Print_MSD:
    swapf   0x7f,f
UART_Print_LSD:
    movlw   0x0f
    andwf   0x7f,w
    addlw   0x36	    ; 0...f --> 0x36... 0x45  
    btfss   STATUS,DC	    ; skip if was a-f
    addlw   0xf9	    ; -=7 => 0...9 --> 0x36...0x3f -> 0x2f...0x39
    addlw   0x01	    ; and follow thropug to tranmit ASCII digit
UART_Put:
    ;banksel PIR1
    ;btfss   PIR1, TXIF        ; Bit Test File, Skip if Set
    ;bra	    UART_Put
    banksel TXREG
    btfss   TX1STA,TRMT
    bra	    UART_Put
    movwf   TXREG	    ; output the characer
    return	

    
UART_Test:
    call    UART_Get
    call    UART_Print
    bra	    UART_Test
    END