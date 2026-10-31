// Offline reference vector matching internal/media.NewFrame. No credentials or network.
package main
import ("encoding/binary"; "encoding/hex"; "fmt")
func main() {
    var frame [120]byte
    copy(frame[:4], "ASMP"); frame[4] = 2; frame[5] = 1
    binary.LittleEndian.PutUint16(frame[6:8], 40)
    id, _ := hex.DecodeString("00112233445546778899aabbccddeeff")
    copy(frame[8:24], id); binary.LittleEndian.PutUint64(frame[24:32], 1)
    binary.LittleEndian.PutUint32(frame[32:36], 80)
    for i := 0; i < 80; i++ { frame[40+i] = byte(i) }
    fmt.Printf("%x\n", frame)
}
