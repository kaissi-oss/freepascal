{
    Copyright (c) 1998-2002 by Florian Klaempfl

    Generate m68k assembler for type converting nodes

    This program is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program; if not, write to the Free Software
    Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.

 ****************************************************************************
}
unit n68kcnv;

{$i fpcdefs.inc}

interface

    uses
      node,ncnv,ncgcnv,defcmp;

    type
       tm68ktypeconvnode = class(tcgtypeconvnode)
         protected
          function first_int_to_real: tnode; override;
          procedure second_int_to_real;override;
          procedure second_int_to_bool;override;
       end;

implementation

   uses
      verbose,globals,systems,
      symconst,symdef,aasmbase,aasmtai,aasmdata,
      defutil,
      cgbase,pass_1,pass_2,procinfo,
      ncon,ncal,
      ncgutil,
      cpubase,cpuinfo,aasmcpu,
      rgobj,tgobj,cgobj,hlcgobj,cgutils,globtype,cgcpu,cutils;


{*****************************************************************************
                             FirstTypeConv
*****************************************************************************}

    function tm68ktypeconvnode.first_int_to_real: tnode;
      var
        fname: string[32];
      begin
        { In case we are in emulation mode, we must
          always call the helpers
        }
        if (cs_fp_emulation in current_settings.moduleswitches)
           or (current_settings.fputype=fpu_soft) then
          begin
            result := inherited first_int_to_real;
            exit;
          end
        else
        { converting a 64bit integer to a float requires a helper }
        if is_64bitint(left.resultdef) or
            is_currency(left.resultdef) then
          begin
            { hack to avoid double division by 10000, as it's
              already done by typecheckpass.resultdef_int_to_real }
            if is_currency(left.resultdef) then
              left.resultdef := s64inttype;

            if is_signed(left.resultdef) then
              fname := 'fpc_int64_to_double'
            else
              fname := 'fpc_qword_to_double';
            result := ccallnode.createintern(fname,ccallparanode.create(
              left,nil));
            left:=nil;
            firstpass(result);
            exit;
          end
        else
          { other integers are supposed to be 32 bit }
          begin
            if is_signed(left.resultdef) then
              inserttypeconv(left,s32inttype)
            else
              { the fpu always considers 32-bit values as signed
                therefore we need to call the helper in case of
                a cardinal value.
              }
              begin
                 fname := 'fpc_longword_to_double';
                 result := ccallnode.createintern(fname,ccallparanode.create(
                    left,nil));
                 left:=nil;
                 firstpass(result);
                 exit;
              end;
            firstpass(left);
          end;
        result := nil;
        location.loc:=LOC_FPUREGISTER;
      end;


{*****************************************************************************
                             SecondTypeConv
*****************************************************************************}



    procedure tm68ktypeconvnode.second_int_to_real;

      var
        ref: treference;
        leftreg: tregister;
        signed : boolean;
        opsize : tcgsize;
      begin
        location_reset(location,LOC_FPUREGISTER,def_cgsize(resultdef));
        signed := is_signed(left.resultdef);
        opsize := def_cgsize(left.resultdef);
        { has to be handled by a helper }
        if is_64bitint(left.resultdef) then
          internalerror(200110011);
        { has to be handled by a helper }
        if not signed then
           internalerror(2002081404);

        location.register:=cg.getfpuregister(current_asmdata.CurrAsmList,opsize);
        if not(left.location.loc in [LOC_REGISTER,LOC_CREGISTER,LOC_REFERENCE,LOC_CREFERENCE]) then
          hlcg.location_force_reg(current_asmdata.CurrAsmList,left.location,left.resultdef,osuinttype,false);
        case left.location.loc of
          LOC_REGISTER, LOC_CREGISTER:
            begin
              leftreg:=tcg68k(cg).force_to_dataregister(current_asmdata.CurrAsmList,left.location.size,left.location.register);
              current_asmdata.CurrAsmList.concat(taicpu.op_reg_reg(A_FMOVE,TCGSize2OpSize[opsize],leftreg,
                  location.register));
            end;
          LOC_REFERENCE,LOC_CREFERENCE:
            begin
              ref:=left.location.reference;
              tcg68k(cg).fixref(current_asmdata.CurrAsmList,ref,false);
              current_asmdata.CurrAsmList.concat(taicpu.op_ref_reg(A_FMOVE,TCGSize2OpSize[opsize],ref,location.register));
            end
          else
            internalerror(200110012);
         end;
       end;


    procedure tm68ktypeconvnode.second_int_to_bool;
      var
        hreg1,
        hreg2    : tregister;
        reg64    : tregister64;
        resflags : tresflags;
        opsize   : tcgsize;
        newsize  : tcgsize;
        hlabel   : tasmlabel;
        tmpreference : treference;
      begin
         secondpass(left);

         { Explicit typecasts from any ordinal type to a boolean type }
         { must not change the ordinal value                          }
         if (nf_explicit in flags) and
            not(left.location.loc in [LOC_FLAGS,LOC_JUMP]) then
           begin
              location_copy(location,left.location);
              newsize:=def_cgsize(resultdef);
              { change of size? change sign only if location is LOC_(C)REGISTER? Then we have to sign/zero-extend }
              if (tcgsize2size[newsize]<>tcgsize2size[left.location.size]) or
                 ((newsize<>left.location.size) and (location.loc in [LOC_REGISTER,LOC_CREGISTER])) then
                hlcg.location_force_reg(current_asmdata.CurrAsmList,location,left.resultdef,resultdef,true)
              else
                location.size:=newsize;
              exit;
           end;

         resflags:=F_NE;

         newsize:=def_cgsize(resultdef);
         opsize := def_cgsize(left.resultdef);

        if (left.location.loc in [LOC_SUBSETREG,LOC_CSUBSETREG,LOC_SUBSETREF,LOC_CSUBSETREF]) then
          hlcg.location_force_reg(current_asmdata.CurrAsmList,left.location,left.resultdef,left.resultdef,true);

         case left.location.loc of
            LOC_CREFERENCE,LOC_REFERENCE :
              begin
                if opsize in [OS_64,OS_S64] then
                  begin
                    //current_asmdata.CurrAsmList.concat(tai_comment.create(strpnew('typeconvnode second_int_to_bool #1')));
                    reg64.reghi:=cg.getintregister(current_asmdata.CurrAsmList,OS_32);
                    reg64.reglo:=cg.getintregister(current_asmdata.CurrAsmList,OS_32);
                    cg64.a_load64_loc_reg(current_asmdata.CurrAsmList,left.location,reg64);
                    current_asmdata.CurrAsmList.concat(taicpu.op_reg_reg(A_OR,S_L,reg64.reghi,reg64.reglo));
                    // it's not necessary to call TST after OR, which sets the flags as required already
                    //current_asmdata.CurrAsmList.concat(taicpu.op_reg(A_TST,S_L,reg64.reglo));
                  end
                else
                  begin
                    //current_asmdata.CurrAsmList.concat(tai_comment.create(strpnew('typeconvnode second_int_to_bool #2')));
                    tmpreference:=left.location.reference;
                    tcg68k(cg).fixref(current_asmdata.CurrAsmList,tmpreference,false);
                    current_asmdata.CurrAsmList.concat(taicpu.op_ref(A_TST,TCGSize2OpSize[opsize],tmpreference));
                  end;
              end;
            LOC_REGISTER,LOC_CREGISTER :
              begin
                if opsize in [OS_64,OS_S64] then
                  begin
                    //current_asmdata.CurrAsmList.concat(tai_comment.create(strpnew('typeconvnode second_int_to_bool #3')));
                    hreg2:=cg.getintregister(current_asmdata.CurrAsmList,opsize);
                    current_asmdata.CurrAsmList.concat(taicpu.op_reg_reg(A_MOVE,S_L,left.location.register64.reglo,hreg2));
                    current_asmdata.CurrAsmList.concat(taicpu.op_reg_reg(A_OR,S_L,left.location.register64.reghi,hreg2));
                    // it's not necessary to call TST after OR, which sets the flags as required already
                    //current_asmdata.CurrAsmList.concat(taicpu.op_reg(A_TST,S_L,hreg2));
                  end
                else
                  begin
                    if (current_settings.cputype = cpu_mc68000) and isaddressregister(left.location.register) then
                      begin
                        hreg2:=cg.getintregister(current_asmdata.CurrAsmList,opsize);
                        cg.a_load_reg_reg(current_asmdata.CurrAsmList,OS_ADDR,opsize,left.location.register,hreg2);
                      end
                    else
                      hreg2:=left.location.register;
                    current_asmdata.CurrAsmList.concat(taicpu.op_reg(A_TST,TCGSize2OpSize[opsize],hreg2));
                  end;
              end;
            LOC_FLAGS :
              begin
                resflags:=left.location.resflags;
              end;
            LOC_JUMP :
              begin
                { for now blindly copied from nx86cnv }
                location_reset(location,LOC_REGISTER,newsize);
                location.register:=cg.getintregister(current_asmdata.CurrAsmList,location.size);
                current_asmdata.getjumplabel(hlabel);
                cg.a_label(current_asmdata.CurrAsmList,left.location.truelabel);
                if not(is_cbool(resultdef)) then
                  cg.a_load_const_reg(current_asmdata.CurrAsmList,location.size,1,location.register)
                else
                  cg.a_load_const_reg(current_asmdata.CurrAsmList,location.size,-1,location.register);
                cg.a_jmp_always(current_asmdata.CurrAsmList,hlabel);
                cg.a_label(current_asmdata.CurrAsmList,left.location.falselabel);
                cg.a_load_const_reg(current_asmdata.CurrAsmList,location.size,0,location.register);
                cg.a_label(current_asmdata.CurrAsmList,hlabel);
              end;
            else
             internalerror(200512182);
         end;
         if left.location.loc<>LOC_JUMP then
           begin
             location_reset(location,LOC_REGISTER,newsize);
             if newsize in [OS_64,OS_S64] then
               begin
                 hreg2:=cg.getintregister(current_asmdata.CurrAsmList,OS_32);
                 cg.g_flags2reg(current_asmdata.CurrAsmList,OS_32,resflags,hreg2);
                 if (is_cbool(resultdef)) then
                   cg.a_op_reg_reg(current_asmdata.CurrAsmList,OP_NEG,OS_32,hreg2,hreg2);
                 location.register64.reglo:=hreg2;
                 location.register64.reghi:=cg.getintregister(current_asmdata.CurrAsmList,OS_32);
                 if (is_cbool(resultdef)) then
                   { reglo is either 0 or -1 -> reghi has to become the same }
                   cg.a_load_reg_reg(current_asmdata.CurrAsmList,OS_32,OS_32,location.register64.reglo,location.register64.reghi)
                 else
                   { unsigned }
                   cg.a_load_const_reg(current_asmdata.CurrAsmList,OS_32,0,location.register64.reghi);
               end
            else
              begin
                location.register:=cg.getintregister(current_asmdata.CurrAsmList,newsize);
                cg.g_flags2reg(current_asmdata.CurrAsmList,newsize,resflags,location.register);
                if (is_cbool(resultdef)) then
                  cg.a_op_reg_reg(current_asmdata.CurrAsmList,OP_NEG,newsize,location.register,location.register);
              end
           end;
      end;


begin
   ctypeconvnode:=tm68ktypeconvnode;
end.
