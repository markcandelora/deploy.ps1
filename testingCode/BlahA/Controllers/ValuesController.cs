using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Configuration;

namespace BlahA.Controllers {
    public class ValuesController : Controller {
        private IConfiguration _configuration;

        public ValuesController(IConfiguration configuration) {
            this._configuration = configuration;
        }

        [HttpGet("/")]
        public IEnumerable<KeyValuePair<string, string>> GetAll() {
            return this._configuration.AsEnumerable();
        }
    }
}
