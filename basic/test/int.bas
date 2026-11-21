A% = 2.7: A = 5: ? A%; A
A% = -1.5: ? A%
A% = -0.5: ? A%
A% = 2147483647.9: ? A%
A% = -2147483648.9: ? A%
A% = 2147483648
A% = -2147483649
? A%
A% = 1E400
FNA% = 1
PROCA% = 1
A%$ = 1
A%(1) = 1
DIM F%(9), D(2): F%(3) = -7.9: F%(9) = 0xFFFFFFFF: ? F%(3); F%(9); F%(0)
F%(1) = 1E10
F%(10) = 1
F%(1.5) = 4: ? F%(1)
DIM G%(2, 3): G%(2, 3) = 23: G%(1, 1) = 11: ? G%(2, 3); G%(1, 1); G%(1, 2)
DIM F%(2)
INPUT X%, F%(2)
3.9, -4.2
? X%; F%(2)
GET F%(4): ? F%(4)
X
FOR I% = 1 TO 3: ? I%;: NEXT
FOR I% = 5 TO 1 STEP -1.5: ? I%;: NEXT
? I%
RCURSOR C%, F%(5): ? C%; F%(5)
NEW
10 DEF FNB(Q%) = Q% * 2
20 DEF PROCP(R%, S): LOCAL T%: T% = S: PRINT R%; T%: ENDPROC
30 T% = 9: PRINT FNB(3.7): PROCP(-2.9, 4.5): PRINT T%
40 DIM W%(2): W%(0) = 1: W%(1) = 2: W%(2) = 3: READ W%(1), K%: PRINT W%(0); W%(1); W%(2); K%
50 DATA 7.5, -8.5
60 A = 1: A% = 2: A$ = "3": PRINT A; A%; A$
LIST
RUN
CLR
? A%
NEW
DIM E(9), E%(9): E%(9) = 9: ? E%(9); PEEK(0xFFFFED65) - 0x8000
DUMP 0x8000, 42
HALT
