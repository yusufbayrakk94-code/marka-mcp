# Marka MCP+

TURKPATENT marka, patent ve tasarım araştırma MCP sunucusu (genişletilmiş sürüm).

Tool listesi: search_trademarks, get_trademark_details, batch_search_trademarks,
search_patents, get_patent_details, batch_search_patents, search_designs,
get_design_details, create_trademark_watch, create_patent_watch,
create_design_watch, list_watches, check_watch, check_all_watches, delete_watch.

Marka sorgularını yapay zekaya bağlayan bir MCP (Model Context Protocol) sunucusu.

AI modellerinin (özellikle Claude Desktop üzerinden) marka verilerine, tescil bilgilerine veya senin tanımladığın marka context'ine direkt erişip analiz yapmasını sağlıyor.

Neden Yaptım?
Marka araştırması yaparken sürekli tarayıcıya git, manuel sorgula, veriyi kopyala-yapıştır yapmaktan sıkıldım. AI'ya "şu markanın durumuna bak" dediğimde işi kendi yapsın diye yazdım.

Nasıl Kullanılır?
Repo'yu çek:

Bash
git clone https://github.com/yusufbayrakk94-code/marka-mcp.git
cd marka-mcp

2. **Kurulum:**
   Bağımlılıkları hallet:
   ```bash
   npm install
   npm run build
Claude Desktop'a Bağla:
~/Library/Application Support/Claude/claude_desktop_config.json dosyasını aç (yoksa oluştur), şunu ekle:

JSON
{
  "mcpServers": {
    "marka": {
      "command": "node",
      "args": ["/SENIN/KLONLADIGIN/YOL/marka-mcp/build/index.js"]
    }
  }
}

4. **Kullan:**
   Claude'u yeniden başlat. Artık Claude'un içinde marka verilerini sorgulayabilirsin.

### Ne Beklemeli?
*   Hızlı sonuç.
*   Doğrudan veriye erişim.
*   Zaman kaybına son.

*Not: Hata alırsan issue aç, oradan çözeriz.*

---

Bu ton daha iyi mi? Eğer içinde spesifik olarak eklememi istediğin teknik bir detay (örneğin spesifik bir veritabanı bağlantısı veya özel bir fonksiyon) varsa söyle, onu da direkt ekleyeyim.
