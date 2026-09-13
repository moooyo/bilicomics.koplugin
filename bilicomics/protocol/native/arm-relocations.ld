/* glibc before the BZ 14341 fix combines these tables under BIND_NOW. */
SECTIONS
{
    .rel.plt : { *(.rel.plt) }
}
INSERT AFTER .rel.dyn;
ASSERT(ADDR(.rel.plt) == ADDR(.rel.dyn) + SIZEOF(.rel.dyn),
       "Linux ARM dynamic and PLT REL tables must remain adjacent")
