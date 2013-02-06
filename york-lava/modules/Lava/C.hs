module Lava.C(writeC) where
import Lava.Bit
import Lava.Binary
import System.Cmd
import Numeric (showHex)
import Data.List
import Data.Maybe (fromJust)
import Data.Graph (Graph, Vertex, graphFromEdges, topSort)

writeC ::
  Generic a => String -- ^ The name of C entity, which is also the
                      -- name of the directory that the output files
                      -- are written to.
            -> a      -- ^ The Bit-structure that is turned into C.
            -> a      -- ^ Names for the outputs of the circuit.
            -> IO ()
writeC name a b =
  do putStrLn ("Creating directory '" ++ name ++ "/'")
     system ("mkdir -p " ++ name)
     nl <- netlist a b
     let csource = genC name nl
     putStrLn $ "Writing to '" ++ name ++ "/" ++ file ++ "'"
     writeFile (name ++ "/" ++ file) csource
     putStrLn "Done."
  where
  file = name ++ ".c"

genC :: String -> Netlist -> String
genC name nl =
  unlines
     [ "typedef int bit;"
     , "/* C simulation function, generated by York Lava, Californicated */"
     , cHeader name nl
     , cDecls regs
     , "  for (;;) {"
     , "  // Calculate the current value of wires, in dependency order"
     , cInsts wires
     , "  if (" ++ exitCond ++ ")"
     , "    return " ++ toScalar (map snd (namedOutputs nl)) ++ ";"
     , "  // Calculate the next values of registers"
     , cRegs regs
     , "  // Update the registers"
     , cRegsUpdate regs
     , "  }"
     , "}"]
  where
  (regs, wires) = partition (isReg . netName) (nets nl)
  isReg n = n `elem` ["delay", "delayEn"]
  exitCond = wireStr $ head [w | ("done", w) <- namedOutputs nl]

toScalar :: [Wire] -> String
toScalar = consperse "+" . zipWith mult powers
  where
  powers = map (floor . (2 **)) [0..]
  mult 1 w = wireStr w
  mult p w = show p ++ "*" ++ wireStr w

cHeader :: String -> Netlist -> String
cHeader name nl = unlines
  [ "unsigned " ++ name ++ "(void) {"
  , "  /* Inputs : " ++ show inps ++ " */"
  , "  /* Outputs: " ++ show outs ++ " */"
  ]
  where
    inps = [ lookupParam (netParams net) "name"
           | net <- nets nl, netName net == "name"]
    outs = map fst (namedOutputs nl)

check name = if name `elem` reserved then
                error $ "`" ++ name ++ "' is a reserved C keyword"
             else
                True
             where
             reserved = ["module", "input", "output", "inout", "reg", "wire", "for",
                         "always", "assign", "begin", "end", "endmodule"]

cDecls :: [Net] -> String
cDecls regs =
  {-
  bracket "  bit " ";\n"
        [ consperse ", " $ map (wireStr . (,) (netId net)) [0..netNumOuts net - 1]
        | net <- wires ]
  ++
  -}
  bracket "  bit " ";\n"
        [ consperse ", " $ map (regFormat net) [0..netNumOuts net - 1]
        | net <- regs ]
  where
    bracket pre post xs = concat [pre ++ x ++ post | x <- xs]
    regFormat net 0 = wireStr (netId net, 0) ++ " = " ++ init net
    regFormat net y = error "unexpected output arity of a register"

    init :: Net -> String
    init net = lookupParam (netParams net) "init"

type Instantiator = String -> [Parameter] -> InstanceId -> [Wire] -> String

cRegs :: [Net] -> String
cRegs regs =
  concat [ cInst (netName net)
                 (netParams net)
                 (netId net)
                 (netInputs net)
         | net <- regs ]

cRegsUpdate :: [Net] -> String
cRegsUpdate regs =
  concat [ cRegUpdate
                 (netName net)
                 (netParams net)
                 (netId net)
                 (netInputs net)
         | net <- regs ]


cInsts :: [Net] -> String
cInsts nets =
  concat [ cInst (netName net)
             (netParams net)
             (netId net)
             (netInputs net)
         | net <- order ]
  where
  edges :: [(Net, Wire, [Wire])]
  edges = [(net, (netId net, 0), netInputs net) | net <- nets]
  netGraph  :: Graph
  vertexMap :: Vertex -> (Net, Wire, [Wire])
  keyMap    :: Wire -> Maybe Vertex
  (netGraph, vertexMap, keyMap) = graphFromEdges edges
  order :: [Net]
  order = reverse [net | v <- topSort netGraph, let (net, w, inputs) = vertexMap v]

cInst :: Instantiator
cInst "low"     = constant "0"
cInst "high"    = constant "1"
cInst "inv"     = gate 1 "~"
cInst "and2"    = gate 1 "&"
cInst "or2"     = gate 1 "|"
cInst "xor2"    = gate 1 "^"
cInst "eq2"     = gate 1 "=="
cInst "xorcy"   = gate 1 "^" -- makes no distinction between xorcy and xor2
cInst "muxcy"   = muxcyInst
cInst "name"    = assignName
cInst "delay"   = delay False
cInst "delayEn" = delay True
cInst "ram"     = instRam
cInst "dualRam" = instRam2
cInst s = error ("C: unknown component '" ++ s ++ "'")

muxcyInst params dst [ci,di,s] =
  "  bit " ++ wireStr (dst, 0) ++ " = " ++
  wireStr s ++ " ? " ++ wireStr ci ++ " : " ++ wireStr di ++ "; // muxcy\n"

mifFiles :: Netlist -> [(String, String)]
mifFiles nl =
    [ ( "ram_" ++ compStr (netId net) ++ ".mif"
      , genMifContents $ netParams net)
    | net <- nets nl
    , netName net == "ram" || netName net == "dualRam"
    , nonEmpty (netParams net)
    ]
  where
    init params = read (lookupParam params "init") :: [Integer]
    nonEmpty params = not $ null $ init params
    genMifContents params = let dwidth = read (lookupParam params "dwidth") :: Int
                                awidth = read (lookupParam params "awidth") :: Int
      in
       unlines
         [ "-- Generated by York Lava, Californicated"
         , "WIDTH=" ++ show dwidth ++ ";"
         , "DEPTH=" ++ show (2^awidth) ++ ";"
         , "ADDRESS_RADIX=HEX;"
         , "DATA_RADIX=HEX;"
         , "CONTENT BEGIN"
         ]
       ++
       unlines
         [ showHex i (':' : showHex v ";")
         | (i,v) <- zip [0..2^awidth-1] (init params ++ repeat 0)
         ]
       ++
       "END;\n"

{-|
For example, the function

> halfAdd :: Bit -> Bit -> (Bit, Bit)
> halfAdd a b = (sum, carry)
>   where
>     sum   = a <#> b
>     carry = a <&> b

can be converted to a C entity with inputs named @a@ and @b@ and
outputs named @sum@ and @carry@.

> synthesiseHalfAdd :: IO ()
> synthesiseHalfAdd =
>   writeC "HalfAdd"
>             (halfAdd (name "a") (name "b"))
>             (name "sum", name "carry")
-}

-- Auxiliary functions

compStr :: InstanceId -> String
compStr i = "c" ++ show i

wireStr :: Wire -> String
wireStr (i, 0) = "w" ++ show i
wireStr (i, j) = "w" ++ show i ++ "_" ++ show j

consperse :: String -> [String] -> String
consperse s [] = ""
consperse s [x] = x
consperse s (x:y:ys) = x ++ s ++ consperse s (y:ys)

argList :: [String] -> String
argList = consperse ","

gate 1 str params comp [i1,i2] =
  "  bit " ++ dest ++ " = " ++ x ++ " " ++ str ++ " " ++ y ++ ";\n"
  where dest = wireStr (comp, 0)
        [x,y] = map wireStr [i1,i2]

gate n str params comp [i] =
  "  bit " ++ dest ++ " = " ++ str ++ wireStr i ++ "; // unary\n"
  where dest = wireStr (comp, 0)

gate n str params comp inps = error $ "gate wasn't expecting " ++ str ++ "," ++ show inps

assignName params comp inps =
  "  bit " ++ wireStr (comp, 0)  ++ " = " ++ lookupParam params "name" ++ "; // assignName\n"

constant str params comp inps =
  "  bit " ++ wireStr (comp, 0) ++ " = " ++ str ++ "; // constant\n"

v_always_at_posedge_clock stmt = "  always @(posedge clock) " ++ stmt ++ "\n"
v_assign dest source = dest ++ " <= " ++ source ++ ";"
v_if_then cond stmt = "if (" ++ cond ++ ") " ++ stmt
v_block stmts = "begin\n" ++
                concat ["    " ++ s ++ "\n" | s <- stmts ] ++
                "  end\n" -- Indents needs more cleverness, like a Doc

delay :: Bool -> [Parameter] -> Int -> [Wire] -> String
delay False params comp [_, d] =
   "  bit " ++ wireStr (comp, 0) ++ "_ = " ++ wireStr d ++ ";\n"

delay True params comp [_, ce, d] =
   "  bit " ++ wireStr (comp, 0) ++ "_ = " ++
          wireStr ce ++
          " ? " ++ wireStr d ++
          " : " ++ wireStr (comp, 0) ++ ";\n"

cRegUpdate "delay"   _ c _ = "  "++wireStr (c, 0)++" = "++wireStr (c, 0)++"_;\n"
cRegUpdate "delayEn" _ c _ = "  "++wireStr (c, 0)++" = "++wireStr (c, 0)++"_;\n"

vBus :: [Wire] -> String
vBus bus = "{" ++ argList (map wireStr (reverse bus)) ++ "}"

instRam params comp (we1:sigs) =
 let  init = read (lookupParam params "init") :: [Integer]
      initFile = "ram_" ++ compStr comp ++ ".mif"
      dwidth = read (lookupParam params "dwidth") :: Int
      awidth = read (lookupParam params "awidth") :: Int

      (dbus1, abus1) = splitAt dwidth sigs
      outs1          = map ((,) comp) [0..dwidth-1]
      c              = " " ++ compStr comp
 in
  "  altsyncram" ++ c ++ "(\n" ++
  "   .clock0 (clock),\n" ++

  "   .address_a (" ++ vBus abus1 ++ "),\n" ++
  "   .wren_a (" ++ wireStr we1 ++ "),\n" ++
  "   .data_a (" ++ vBus dbus1 ++ "),\n" ++
  "   .q_a (" ++ vBus outs1 ++ "),\n" ++

  "   .address_b (1'b1),\n" ++
  "   .wren_b (1'b0),\n" ++
  "   .data_b (1'b1),\n" ++
  "   .q_b (),\n" ++

  "   .aclr0 (1'b0),\n" ++
  "   .aclr1 (1'b0),\n" ++
  "   .addressstall_a (1'b0),\n" ++
  "   .addressstall_b (1'b0),\n" ++
  "   .byteena_a (1'b1),\n" ++
  "   .byteena_b (1'b1),\n" ++
  "   .clock1 (1'b1),\n" ++
  "   .clocken0 (1'b1),\n" ++
  "   .clocken1 (1'b1),\n" ++
  "   .clocken2 (1'b1),\n" ++
  "   .clocken3 (1'b1),\n" ++
  "   .eccstatus (),\n" ++
  "   .rden_a (1'b1),\n" ++
  "   .rden_b (1'b1));\n" ++
  "  defparam\n" ++
  c ++ ".clock_enable_input_a = \"BYPASS\",\n" ++
  c ++ ".clock_enable_output_a = \"BYPASS\",\n" ++
  (if null init then "" else c ++ ".init_file = \"" ++ initFile ++ "\",\n") ++
  c ++ ".lpm_type = \"altsyncram\",\n" ++
  c ++ ".numwords_a = " ++ show (2^awidth) ++ ",\n" ++
  c ++ ".operation_mode = \"SINGLE_PORT\",\n" ++
  c ++ ".outdata_aclr_a = \"NONE\",\n" ++
  c ++ ".outdata_reg_a = \"UNREGISTERED\",\n" ++
  c ++ ".power_up_uninitialized = \"FALSE\",\n" ++
  c ++ ".read_during_write_mode_port_a = \"NEW_DATA_NO_NBE_READ\",\n" ++
  c ++ ".widthad_a = " ++ show awidth ++ ",\n" ++
  c ++ ".width_a = " ++ show dwidth ++ ",\n" ++
  c ++ ".width_byteena_a = 1,\n" ++
  c ++ ".width_byteena_b = 1;\n"


instRam2 params comp (we1:we2:sigs) =
 let  init = read (lookupParam params "init") :: [Integer]
      initFile = "ram_" ++ compStr comp ++ ".mif"
      dwidth = read (lookupParam params "dwidth") :: Int
      awidth = read (lookupParam params "awidth") :: Int

      (dbus, abus)   = splitAt (2*dwidth) sigs
      (abus1, abus2) = splitAt awidth abus
      (dbus1, dbus2) = splitAt dwidth dbus
      outs1          = map ((,) comp) [0..dwidth-1]
      outs2          = map ((,) comp) [dwidth..dwidth*2-1]
      c              = " " ++ compStr comp
 in
  "  altsyncram" ++ c ++ "(\n" ++
  "   .clock0 (clock),\n" ++

  "   .address_a (" ++ vBus abus1 ++ "),\n" ++
  "   .wren_a (" ++ wireStr we1 ++ "),\n" ++
  "   .data_a (" ++ vBus dbus1 ++ "),\n" ++
  "   .q_a (" ++ vBus outs1 ++ "),\n" ++

  "   .address_b (" ++ vBus abus2 ++ "),\n" ++
  "   .wren_b (" ++ wireStr we2 ++ "),\n" ++
  "   .data_b (" ++ vBus dbus2 ++ "),\n" ++
  "   .q_b (" ++ vBus outs2 ++ "),\n" ++

  "   .aclr0 (1'b0),\n" ++
  "   .aclr1 (1'b0),\n" ++
  "   .addressstall_a (1'b0),\n" ++
  "   .addressstall_b (1'b0),\n" ++
  "   .byteena_a (1'b1),\n" ++
  "   .byteena_b (1'b1),\n" ++
  "   .clock1 (1'b1),\n" ++
  "   .clocken0 (1'b1),\n" ++
  "   .clocken1 (1'b1),\n" ++
  "   .clocken2 (1'b1),\n" ++
  "   .clocken3 (1'b1),\n" ++
  "   .eccstatus (),\n" ++
  "   .rden_a (1'b1),\n" ++
  "   .rden_b (1'b1));\n" ++
  "  defparam\n" ++
  c ++ ".address_reg_b = \"CLOCK0\",\n" ++
  c ++ ".clock_enable_input_a = \"BYPASS\",\n" ++
  c ++ ".clock_enable_input_b = \"BYPASS\",\n" ++
  c ++ ".clock_enable_output_a = \"BYPASS\",\n" ++
  c ++ ".clock_enable_output_b = \"BYPASS\",\n" ++
  c ++ ".indata_reg_b = \"CLOCK0\",\n" ++
  (if null init then "" else c ++ ".init_file = \"" ++ initFile ++ "\",\n") ++
  c ++ ".lpm_type = \"altsyncram\",\n" ++
  c ++ ".numwords_a = " ++ show (2^awidth) ++ ",\n" ++
  c ++ ".numwords_b = " ++ show (2^awidth) ++ ",\n" ++
  c ++ ".operation_mode = \"BIDIR_DUAL_PORT\",\n" ++
  c ++ ".outdata_aclr_a = \"NONE\",\n" ++
  c ++ ".outdata_aclr_b = \"NONE\",\n" ++
  c ++ ".outdata_reg_a = \"UNREGISTERED\",\n" ++
  c ++ ".outdata_reg_b = \"UNREGISTERED\",\n" ++
  c ++ ".power_up_uninitialized = \"FALSE\",\n" ++
  c ++ ".read_during_write_mode_mixed_ports = \"DONT_CARE\",\n" ++
  c ++ ".read_during_write_mode_port_a = \"NEW_DATA_NO_NBE_READ\",\n" ++
  c ++ ".read_during_write_mode_port_b = \"NEW_DATA_NO_NBE_READ\",\n" ++
  c ++ ".widthad_a = " ++ show awidth ++ ",\n" ++
  c ++ ".widthad_b = " ++ show awidth ++ ",\n" ++
  c ++ ".width_a = " ++ show dwidth ++ ",\n" ++
  c ++ ".width_b = " ++ show dwidth ++ ",\n" ++
  c ++ ".width_byteena_a = 1,\n" ++
  c ++ ".width_byteena_b = 1,\n" ++
  c ++ ".wrcontrol_wraddress_reg_b = \"CLOCK0\";\n"
