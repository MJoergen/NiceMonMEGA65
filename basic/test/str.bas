A$ = "HELLO": B$ = "WORLD": ? A$; " "; B$
C$ = A$ + ", " + B$ + "!": ? C$; LEN(C$)
? LEFT$(C$, 5); "|"; RIGHT$(C$, 6); "|"; MID$(C$, 8, 5); "|"; MID$(C$, 8)
? LEFT$(A$, 0); "|"; LEFT$(A$, 99); "|"; MID$(A$, 9); "|"; RIGHT$(A$, 9)
? ASC("A"); CHR$(66); STR$(1/3); "|"; STR$(-12); "|"; HEX$(255); "|"; HEX$(-1)
? VAL("12.5"); VAL("  -3E2X"); VAL("0x1F"); VAL("ABC"); VAL(""); VAL("+ 7")
? INSTR("BANANA", "NA"); INSTR("BANANA", "NA", 4); INSTR("BANANA", "X"); INSTR("AB", ""); INSTR("AB", "", 3)
? "ABC" = "ABC"; "ABC" < "ABD"; "AB" < "ABC"; "B" > "ABC"; "A" <> "A"; "" = ""
IF A$ = "HELLO" AND B$ >= "W" THEN ? "YES" ELSE ? "NO"
? NOT A$ = "X"; (A$ = "HELLO") + 1
D$ = A$: A$ = "BYE": ? D$; " "; A$
E$ = "": ? LEN(E$); "["; E$; "]"
? (A$ + "X") + ("Y" + B$)
? LEN(CHR$(0)); ASC(CHR$(255))
? 1 + A$ = "X"
? A$ + 1
X = A$
? LEN(5)
? Z$
? ASC("")
? CHR$(256)
? MID$("A", 0)
? LEFT$("A", -1)
F$ = LEFT$("ABCDEFGHIJ", 5) + RIGHT$("ABCDEFGHIJ", 5): ? F$
DIM S$(3), T$(1, 2): ? "["; S$(0); "]"; LEN(T$(1, 2))
S$(1) = "ONE": T$(1, 2) = S$(1) + "TWO": ? S$(1); T$(1, 2)
G$ = "0123456789012345678901234567890123456789012345678901234567890123456789"
G$ = G$ + G$ + G$: ? LEN(G$)
G$ = G$ + G$
? LEN(G$)
IP "1.2.3." + "4": IP
H$ = "4.3.2.1": IP H$: IP
TIME$ = "2026-11-20 12:00:00": ? TIME$
TIME$ = "BAD"
GET K$: ? "["; K$; "]"
Q
K$ = "KEPT"
10 REM
? K$
CLR: ? K$
NEW
5 DIM C(2)
10 READ A, B$, C(1)
20 PRINT A; B$; C(1)
30 READ D$, E: PRINT D$; E
40 RESTORE 60: READ F$: PRINT F$
50 RESTORE: READ G: PRINT G
60 DATA 1, "A,B" , 3.5 : DATA HELLO WORLD , -4
70 READ X$, Y$: PRINT "["; X$; "]["; Y$; "]"
80 DATA ,
90 READ Z
100 A$ = TIME$ + CHR$(65) + MID$("XYZ", 2) + STR$(-1): IF A$ <> "" THEN PRINT LEN(A$); INSTR(A$, "A") > 0; VAL("1")
110 READ Z$, Z, Z$, Z$, Z$
LIST
RUN
RUN 70
NEW
10 INPUT "NAME"; N$, M: PRINT "["; N$; "]"; M
20 INPUT N$: PRINT N$
RUN
  ALICE  , 5
"B, C"
RUN
"D" X, 1
D, 2
E
NEW
10 HIMEM = 0x8800
20 DIM A$(9)
30 FOR I = 1 TO 2000
40 A$(I MOD 10) = STR$(I) + "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
50 NEXT
60 FOR I = 0 TO 9: PRINT A$(I);" ";: NEXT: PRINT
70 B$ = "X": FOR I = 1 TO 200: B$ = B$ + "Y": C$ = LEFT$(B$, I MOD 7) + B$: NEXT: PRINT LEN(B$); LEN(C$)
RUN
HALT
